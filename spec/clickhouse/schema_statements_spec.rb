# frozen_string_literal: true

RSpec.describe "ClickHouse schema statements" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute(<<~SQL.squish)
      CREATE TABLE IF NOT EXISTS schema_probe (
        device_id UInt64,
        ts        DateTime64(3, 'UTC') DEFAULT now64(3),
        note      Nullable(String),
        tag       LowCardinality(String) DEFAULT 'none',
        active    Bool DEFAULT true,
        INDEX idx_note note TYPE bloom_filter GRANULARITY 4
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (device_id, ts)
    SQL
    conn.execute("CREATE VIEW IF NOT EXISTS schema_probe_view AS SELECT device_id FROM schema_probe")
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP VIEW IF EXISTS schema_probe_view")
    conn.execute("DROP TABLE IF EXISTS schema_probe")
  end

  it "lists base tables without views" do
    expect(connection.tables).to include("schema_probe")
    expect(connection.tables).not_to include("schema_probe_view")
  end

  it "lists views" do
    expect(connection.views).to include("schema_probe_view")
  end

  it "confirms table existence" do
    expect(connection.table_exists?("schema_probe")).to be(true)
    expect(connection.table_exists?("nope_not_here")).to be(false)
  end

  it "returns column objects with ClickHouse sql types" do
    ts = connection.columns("schema_probe").find { |column| column.name == "ts" }
    expect(ts.sql_type).to eq("DateTime64(3, 'UTC')")
  end

  it "maps integer columns to :integer" do
    device_id = connection.columns("schema_probe").find { |column| column.name == "device_id" }
    expect(device_id.type).to eq(:integer)
  end

  it "marks Nullable columns as null and bare columns as not null" do
    columns = connection.columns("schema_probe").index_by(&:name)
    expect(columns.fetch("note").null).to be(true)
    expect(columns.fetch("device_id").null).to be(false)
  end

  it "sees through LowCardinality for the AR type" do
    tag = connection.columns("schema_probe").find { |column| column.name == "tag" }
    expect(tag.type).to eq(:string)
  end

  it "captures DEFAULT expressions as default_function" do
    ts = connection.columns("schema_probe").find { |column| column.name == "ts" }
    expect(ts.default_function).to eq("now64(3)")
  end

  it "captures literal defaults as values" do
    tag = connection.columns("schema_probe").find { |column| column.name == "tag" }
    expect(tag.default).to eq("none")
  end

  # A boolean default is a literal, not a function: auto_populated? must stay false
  # or Rails asks for the column back via RETURNING (which ClickHouse lacks).
  it "captures boolean defaults as cast values" do
    active = connection.columns("schema_probe").find { |column| column.name == "active" }
    expect(active.default).to be(true)
  end

  it "leaves boolean defaults out of default_function" do
    active = connection.columns("schema_probe").find { |column| column.name == "active" }
    expect(active.default_function).to be_nil
  end

  it "lists data skipping indexes" do
    index = connection.indexes("schema_probe").first
    expect(index.name).to eq("idx_note")
  end

  it "renames a table keeping its rows" do
    connection.create_table("rename_probe", force: true, order: "id") { |t| t.integer :id, limit: 8 }
    connection.execute("INSERT INTO rename_probe VALUES (7)")
    connection.rename_table("rename_probe", "renamed_probe")
    expect(connection.select_value("SELECT id FROM renamed_probe")).to eq(7)
  ensure
    connection.drop_table("rename_probe", if_exists: true)
    connection.drop_table("renamed_probe", if_exists: true)
  end

  it "reports no Active Record primary key (ClickHouse sorting keys are not unique)" do
    expect(connection.primary_keys("schema_probe")).to eq([])
  end
end
