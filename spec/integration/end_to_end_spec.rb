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

  it "updates matching rows with a mutation" do
    model.where(event_type: "render").update_all(duration_ms: 0)
    expect(model.where(event_type: "render").distinct.pluck(:duration_ms)).to eq([0])
  end

  it "deletes matching rows with a lightweight delete" do
    model.where(device_id: 1).delete_all
    expect(model.pluck(:device_id)).to eq([2])
  end

  it "scopes a query with per-query SETTINGS" do
    expect(model.settings(max_threads: 1).count).to eq(3)
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
end
