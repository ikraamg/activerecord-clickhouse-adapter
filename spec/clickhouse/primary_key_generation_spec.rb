# frozen_string_literal: true

# Decision (2026-07-13): ClickHouse has no autoincrement and no INSERT ... RETURNING,
# so the adapter prefetches primary keys client-side (the Oracle-adapter seam):
# Int* columns get time-ordered 63-bit ids, UUID columns get UUIDv7.
RSpec.describe "ClickHouse client-side primary key generation" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  let(:integer_model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "pk_gen_events"
      self.primary_key = "id"

      def self.name = "PkGenEvent"
    end
  end

  let(:uuid_model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "pk_gen_documents"
      self.primary_key = "id"

      def self.name = "PkGenDocument"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("pk_gen_events", if_exists: true)
    conn.drop_table("pk_gen_documents", if_exists: true)
    conn.create_table("pk_gen_events", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :name, default: ""
    end
    conn.create_table("pk_gen_documents", order: "id") do |t|
      t.column :id, :uuid
      t.string :title, default: ""
    end
    conn.drop_table("pk_gen_readings", if_exists: true)
    conn.create_table("pk_gen_readings", order: "(device_id, id)") do |t|
      t.integer :device_id, limit: 8
      t.integer :id, limit: 8
    end
    conn.drop_table("pk_gen_stamped", if_exists: true)
    conn.create_table("pk_gen_stamped", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label, default: ""
      t.datetime :stamped_at, precision: 6, default: -> { "now64(6)" }
    end
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("pk_gen_events", if_exists: true)
    conn.drop_table("pk_gen_documents", if_exists: true)
    conn.drop_table("pk_gen_readings", if_exists: true)
    conn.drop_table("pk_gen_stamped", if_exists: true)
  end

  before do
    connection.execute("TRUNCATE TABLE pk_gen_events")
    connection.execute("TRUNCATE TABLE pk_gen_documents")
  end

  it "prefetches primary keys when the sorting key is one generatable column" do
    expect(connection.prefetch_primary_key?("pk_gen_events")).to be(true)
  end

  it "does not prefetch when the sorting key is composite" do
    expect(connection.prefetch_primary_key?("pk_gen_readings")).to be(false)
  end

  it "assigns a generated id on create!" do
    expect(integer_model.create!(name: "first").id).to be_a(Integer)
  end

  it "persists the generated id so the record is findable" do
    record = integer_model.create!(name: "first")
    expect(integer_model.find(record.id).name).to eq("first")
  end

  it "generates distinct ids across creates" do
    ids = Array.new(5) { integer_model.create!.id }
    expect(ids.uniq.length).to eq(5)
  end

  it "generates time-ordered ids across creates" do
    earlier = integer_model.create!.id
    sleep 0.002
    expect(integer_model.create!.id).to be > earlier
  end

  it "keeps generated integer ids inside signed Int64" do
    expect(integer_model.create!.id).to be < 2**63
  end

  it "respects an explicitly assigned id" do
    expect(integer_model.create!(id: 42, name: "manual").id).to eq(42)
  end

  it "assigns a UUIDv7 to uuid primary keys" do
    expect(uuid_model.create!(title: "spec").id)
      .to match(/\A\h{8}-\h{4}-7\h{3}-[89ab]\h{3}-\h{12}\z/)
  end

  it "persists the generated uuid so the record is findable" do
    record = uuid_model.create!(title: "spec")
    expect(uuid_model.find(record.id).title).to eq("spec")
  end

  it "raises for primary key types it cannot generate" do
    expect { connection.next_sequence_value("pk_gen_events.name") }
      .to raise_error(ActiveRecord::ActiveRecordError, /cannot generate/i)
  end

  it "raises for a nil sequence (composite primary keys have none)" do
    expect { connection.next_sequence_value(nil) }
      .to raise_error(ActiveRecord::ActiveRecordError, /cannot generate/i)
  end

  # Models may override sequence_name with an arbitrary label (Oracle legacy, e.g.
  # Rails' own Company model); the prefetch gate already vetted the table.
  it "generates integer ids for custom sequence labels" do
    expect(connection.next_sequence_value("events_nonstd_seq")).to be_a(Integer)
  end

  # Rails asks for auto-populated columns back after insert; without RETURNING the
  # prefetched pk is the only value the adapter can supply, and it must land on the
  # pk attribute — not on whichever default-function column Rails listed first.
  describe "write-back alongside default-function columns" do
    let(:stamped_model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = "pk_gen_stamped"
        self.primary_key = "id"

        def self.name = "PkGenStamped"
      end
    end

    before { connection.execute("TRUNCATE TABLE pk_gen_stamped") }

    it "assigns the generated id to the pk attribute" do
      expect(stamped_model.create!(label: "probe").id).to be_a(Integer)
    end

    it "does not write the id into the default-function column" do
      record = stamped_model.create!(label: "probe")
      expect(record.reload.stamped_at).to be_within(60).of(Time.now.utc)
    end
  end

  # Rails checks prefetch_primary_key? on every create; without a cache that is one
  # system.tables query per insert.
  describe "sorting-key cache" do
    def sorting_key_queries(&)
      queries = []
      counter = lambda do |event|
        queries << event.payload[:sql] if event.payload[:sql].include?("sorting_key")
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &)
      queries
    end

    it "answers repeat prefetch checks without re-querying the server" do
      connection.prefetch_primary_key?("pk_gen_events")
      expect(sorting_key_queries { 3.times { connection.prefetch_primary_key?("pk_gen_events") } }).to be_empty
    end

    it "reuses the cached column across generated inserts" do
      integer_model.create!(name: "warm")
      expect(sorting_key_queries { integer_model.create!(name: "cached") }).to be_empty
    end

    it "invalidates when the table is recreated with a different key" do
      connection.prefetch_primary_key?("pk_gen_events")
      connection.create_table("pk_gen_events", force: true, order: "name") do |t|
        t.string :name
      end
      expect(connection.prefetch_primary_key?("pk_gen_events")).to be(false)
    ensure
      connection.create_table("pk_gen_events", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.string :name, default: ""
      end
    end

    it "invalidates when the table is dropped" do
      connection.prefetch_primary_key?("pk_gen_events")
      connection.drop_table("pk_gen_events")
      expect(connection.prefetch_primary_key?("pk_gen_events")).to be(false)
    ensure
      connection.create_table("pk_gen_events", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.string :name, default: ""
      end
    end

    it "invalidates when the table is renamed" do
      connection.create_table("pk_gen_original", force: true, order: "id") { |t| t.integer :id, limit: 8 }
      connection.prefetch_primary_key?("pk_gen_original")
      connection.rename_table("pk_gen_original", "pk_gen_renamed")
      expect(connection.prefetch_primary_key?("pk_gen_original")).to be(false)
    ensure
      connection.drop_table("pk_gen_original", if_exists: true)
      connection.drop_table("pk_gen_renamed", if_exists: true)
    end
  end
end
