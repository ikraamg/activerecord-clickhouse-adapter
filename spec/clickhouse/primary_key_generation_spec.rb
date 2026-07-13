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
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("pk_gen_events", if_exists: true)
    conn.drop_table("pk_gen_documents", if_exists: true)
    conn.drop_table("pk_gen_readings", if_exists: true)
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
end
