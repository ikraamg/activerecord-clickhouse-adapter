# frozen_string_literal: true

# The e2e spine (AUTONOMOUS_RUN.md): one realistic model exercised through the full
# stack, extended with each phase's new capability.
RSpec.describe "End-to-end telemetry spine" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "spine_events"

      def self.name = "SpineEvent"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("spine_events", if_exists: true)
    conn.create_table("spine_events", order: "(device_id, ts)", partition: "toDate(ts)") do |t|
      t.integer :device_id, limit: 8
      t.datetime :ts, precision: 3, default: -> { "now64(3)" }
      t.string :event_type, low_cardinality: true, default: ""
      t.integer :duration_ms, null: true
      t.boolean :scheduled, default: false
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("spine_events", if_exists: true)
  end

  before do
    ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE spine_events")
    model.create!(device_id: 1, ts: Time.utc(2026, 7, 1, 8, 0), event_type: "render", duration_ms: 120)
    model.create!(device_id: 1, ts: Time.utc(2026, 7, 1, 9, 0), event_type: "serve", duration_ms: 30)
    model.create!(device_id: 2, ts: Time.utc(2026, 7, 1, 9, 30), event_type: "render", duration_ms: 80,
                  scheduled: true)
  end

  it "counts through the relation" do
    expect(model.count).to eq(3)
  end

  it "filters with where and reads typed attributes back" do
    event = model.where(device_id: 2).take
    expect(event.ts).to eq(Time.utc(2026, 7, 1, 9, 30))
  end

  it "casts boolean attributes round-trip" do
    expect(model.where(device_id: 2).take.scheduled).to be(true)
  end

  it "treats missing nullable values as nil" do
    model.create!(device_id: 3, event_type: "checkin")
    expect(model.where(device_id: 3).take.duration_ms).to be_nil
  end

  it "orders and plucks" do
    expect(model.order(:ts).pluck(:event_type)).to eq(%w[render serve render])
  end

  it "computes calculations server-side" do
    expect(model.where(event_type: "render").average(:duration_ms)).to eq(100)
  end

  it "groups with aggregates" do
    expect(model.group(:device_id).count).to eq(1 => 2, 2 => 1)
  end

  it "buckets a time series by hour" do
    series = model.group_by_period(:hour, :ts).count
    expect(series[Time.utc(2026, 7, 1, 9)]).to eq(2)
  end

  it "adds a grand-total row via rollup" do
    expect(model.group(:device_id).rollup.count.fetch(nil)).to eq(3)
  end

  it "answers percentiles server-side" do
    expect(model.quantile(1.0, :duration_ms)).to eq(120)
  end

  it "answers the dominant event type via top_k" do
    expect(model.top_k(1, :event_type)).to eq(["render"])
  end

  it "estimates the table's row count from metadata" do
    expect(model.estimated_count).to eq(3)
  end

  it "emits sql.active_record notifications for relation queries" do
    payloads = []
    callback = ->(event) { payloads << event.payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { model.count }
    expect(payloads).to include(a_string_including("SELECT COUNT(*)"))
  end

  it "bulk-inserts a batch in one statement" do
    model.insert_all!([
                        { device_id: 5, event_type: "checkin" },
                        { device_id: 5, event_type: "render" }
                      ])
    expect(model.where(device_id: 5).count).to eq(2)
  end

  it "streams a lazy batch through one chunked insert" do
    rows = (1..500).lazy.map { |n| { device_id: 100 + n, event_type: "stream" } }
    model.insert_stream(rows)
    expect(model.where(event_type: "stream").count).to eq(500)
  end

  it "updates matching rows with a mutation" do
    model.where(event_type: "render").update_all(duration_ms: 0)
    expect(model.where(event_type: "render").distinct.pluck(:duration_ms)).to eq([0])
  end

  it "reports how many rows a mutation touched" do
    expect(model.where(event_type: "render").update_all(duration_ms: 0)).to eq(2)
  end

  it "deletes matching rows with a lightweight delete" do
    model.where(device_id: 1).delete_all
    expect(model.pluck(:device_id)).to eq([2])
  end

  it "reports how many rows a delete removed" do
    expect(model.where(device_id: 1).delete_all).to eq(2)
  end

  it "scopes a query with per-query SETTINGS" do
    expect(model.settings(max_threads: 1).count).to eq(3)
  end

  it "matches nothing when finding by a nil condition" do
    expect(model.where(duration_ms: nil).count).to eq(0)
  end

  it "answers a conditional aggregate in one scan" do
    expect(model.uniq_count(:device_id, if: { event_type: "render" })).to eq(2)
  end

  it "projects a window expression alongside the row" do
    positions = model.window(:row_number, as: :position, partition_by: :device_id, order_by: :ts)
                     .order(:device_id, :ts).map { |row| row[:position] }
    expect(positions).to eq([1, 2, 1])
  end

  it "resolves device names through a dictionary instead of a JOIN" do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("CREATE TABLE spine_devices (id UInt64, name String) ENGINE = MergeTree ORDER BY id")
    conn.execute("INSERT INTO spine_devices VALUES (1, 'lobby'), (2, 'office')")
    conn.create_dictionary("spine_device_names", source: "spine_devices", primary_key: :id)
    names = model.dict_get("spine_device_names", :name, key: :device_id).order(:ts).map { |row| row[:name] }
    expect(names).to eq(%w[lobby lobby office])
  ensure
    conn.execute("DROP DICTIONARY IF EXISTS spine_device_names")
    conn.drop_table("spine_devices", if_exists: true)
  end

  describe "the pre-aggregation pipeline (MV -> AggregatingMergeTree -> merged reads)" do
    subject(:daily_model) do
      Class.new(ActiveRecord::Base) do
        include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

        self.table_name = "spine_daily"

        def self.name = "SpineDaily"
      end
    end

    before(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.drop_materialized_view("spine_daily_rollup", if_exists: true)
      conn.drop_table("spine_daily", if_exists: true)
      conn.create_table("spine_daily", engine: "AggregatingMergeTree", order: "day") do |t|
        t.date :day
        t.column :devices, "AggregateFunction(uniq, Int64)"
        t.column :total_ms, "SimpleAggregateFunction(sum, Nullable(Int64))"
      end
      conn.create_materialized_view("spine_daily_rollup", to: "spine_daily", as: <<~SQL.squish)
        SELECT toDate(ts) AS day, uniqState(device_id) AS devices,
               sum(toNullable(toInt64(duration_ms))) AS total_ms
        FROM spine_events GROUP BY day
      SQL
    end

    after(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.drop_materialized_view("spine_daily_rollup", if_exists: true)
      conn.drop_table("spine_daily", if_exists: true)
    end

    before { ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE spine_daily") }

    it "streams inserts through the view and merges distinct counts" do
      model.create!(device_id: 9, ts: Time.utc(2026, 7, 2, 8), event_type: "render", duration_ms: 5)
      expect(daily_model.where(day: Date.new(2026, 7, 2)).uniq_count(:devices, merge: true)).to eq(1)
    end

    it "sums simple aggregate columns with plain Rails sum" do
      model.create!(device_id: 9, ts: Time.utc(2026, 7, 2, 8), event_type: "render", duration_ms: 5)
      model.create!(device_id: 9, ts: Time.utc(2026, 7, 2, 9), event_type: "render", duration_ms: 7)
      expect(daily_model.where(day: Date.new(2026, 7, 2)).sum(:total_ms)).to eq(12)
    end
  end

  it "matches nothing when finding by an empty id list" do
    expect(model.where(device_id: []).count).to eq(0)
  end

  it "explains index pruning on the sorting key" do
    expect(model.where(device_id: 1).explain(:indexes).inspect).to include("PrimaryKey")
  end

  # count() is answered from metadata (optimize_trivial_count_query: read_rows 1), so a
  # real column aggregation is needed to observe rows being read.
  it "surfaces server-side read stats in the notification payload" do
    stats = []
    callback = ->(event) { stats << event.payload[:clickhouse] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { model.sum(:duration_ms) }
    expect(stats.last).to include(read_rows: 3)
  end

  it "surfaces server-side write stats in the notification payload" do
    stats = []
    callback = ->(event) { stats << event.payload[:clickhouse] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      model.insert_all!([{ device_id: 9, event_type: "checkin" }, { device_id: 9, event_type: "render" }])
    end
    expect(stats.last).to include(written_rows: 2)
  end

  it "creates and finds records through a generated primary key" do
    audit_model = Class.new(ActiveRecord::Base) do
      self.table_name = "spine_audits"
      self.primary_key = "id"

      def self.name = "SpineAudit"
    end
    connection = ActiveRecord::Base.lease_connection
    connection.drop_table("spine_audits", if_exists: true)
    connection.create_table("spine_audits", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :action, default: ""
    end
    record = audit_model.create!(action: "deploy")
    expect(audit_model.find(record.id).action).to eq("deploy")
  ensure
    ActiveRecord::Base.lease_connection.drop_table("spine_audits", if_exists: true)
  end

  # Two joins trigger the analyzer's qualified-star renaming (spine_events.device_id);
  # the adapter strips the qualifiers so attributes map by bare name as Rails expects.
  it "reads whole rows through a multi-join without losing attribute names" do
    connection = ActiveRecord::Base.lease_connection
    connection.drop_table("spine_devices", if_exists: true)
    connection.create_table("spine_devices", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label, default: ""
    end
    connection.execute("INSERT INTO spine_devices VALUES (1, 'lobby'), (2, 'kitchen')")

    event = model.select("spine_events.*")
                 .joins("INNER JOIN spine_devices ON spine_devices.id = spine_events.device_id")
                 .joins("INNER JOIN spine_devices AS twins ON twins.id = spine_events.device_id")
                 .where(event_type: "serve").take
    expect(event.duration_ms).to eq(30)
  ensure
    ActiveRecord::Base.lease_connection.drop_table("spine_devices", if_exists: true)
  end

  it "survives a schema dump, reload, and re-query round trip" do
    ActiveRecord::SchemaDumper.ignore_tables = [->(table) { table != "spine_events" }]
    dump = ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
    ActiveRecord::Base.lease_connection.drop_table("spine_events")
    eval(dump) # rubocop:disable Security/Eval -- loading the dump is the point
    model.reset_column_information
    model.create!(device_id: 7, ts: Time.utc(2026, 7, 2, 10, 0), event_type: "render", duration_ms: 55)
    expect(model.where(device_id: 7).pluck(:duration_ms)).to eq([55])
  ensure
    ActiveRecord::SchemaDumper.ignore_tables = []
  end
end
