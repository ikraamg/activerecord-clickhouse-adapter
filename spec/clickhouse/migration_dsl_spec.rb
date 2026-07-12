# frozen_string_literal: true

RSpec.describe "ClickHouse migration DSL" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  after do
    connection.execute("DROP TABLE IF EXISTS dsl_probe")
  end

  def create_dsl_probe(**options, &block)
    connection.create_table("dsl_probe", **options, &block)
  end

  def show_create = connection.select_value("SHOW CREATE TABLE dsl_probe").tr("\n", " ").squeeze(" ")

  it "creates a MergeTree table with ORDER BY from options" do
    create_dsl_probe(order: "(device_id, ts)") do |t|
      t.integer :device_id, null: false
      t.datetime :ts
    end

    expect(show_create).to include("ENGINE = MergeTree", "ORDER BY (device_id, ts)")
  end

  it "omits the id column by default" do
    create_dsl_probe(order: "device_id") { |t| t.integer :device_id }

    expect(connection.columns("dsl_probe").map(&:name)).to eq(["device_id"])
  end

  it "renders partition, ttl and settings clauses" do
    create_dsl_probe(
      order: "(device_id, ts)",
      partition: "toDate(ts)",
      ttl: "toDateTime(ts) + INTERVAL 30 DAY",
      settings: { index_granularity: 8192 }
    ) do |t|
      t.integer :device_id
      t.datetime :ts
    end

    # SHOW CREATE normalizes INTERVAL 30 DAY into toIntervalDay(30).
    expect(show_create).to include(
      "PARTITION BY toDate(ts)",
      "TTL toDateTime(ts) + toIntervalDay(30)",
      "index_granularity = 8192"
    )
  end

  it "renders a custom engine" do
    create_dsl_probe(engine: "ReplacingMergeTree(ver)", order: "k") do |t|
      t.string :k
      t.datetime :ver
    end

    expect(show_create).to include("ENGINE = ReplacingMergeTree(ver)")
  end

  it "maps null: true to Nullable and default nullability to NOT-Nullable" do
    create_dsl_probe(order: "device_id") do |t|
      t.integer :device_id
      t.string :note, null: true
    end

    note = connection.columns("dsl_probe").find { |column| column.name == "note" }
    expect(note.sql_type).to eq("Nullable(String)")
  end

  it "maps integer limits onto sized ClickHouse integers" do
    create_dsl_probe(order: "small") do |t|
      t.integer :small, limit: 1
      t.integer :medium, limit: 4
      t.bigint :big
    end

    types = connection.columns("dsl_probe").to_h { |column| [column.name, column.sql_type] }
    expect(types).to eq("small" => "Int8", "medium" => "Int32", "big" => "Int64")
  end

  it "supports low_cardinality string columns" do
    create_dsl_probe(order: "device_id") do |t|
      t.integer :device_id
      t.string :tag, low_cardinality: true, default: ""
    end

    tag = connection.columns("dsl_probe").find { |column| column.name == "tag" }
    expect(tag.sql_type).to eq("LowCardinality(String)")
  end

  it "renders literal column defaults" do
    create_dsl_probe(order: "device_id") do |t|
      t.integer :device_id
      t.string :status, default: "new"
    end

    status = connection.columns("dsl_probe").find { |column| column.name == "status" }
    expect(status.default).to eq("new")
  end

  it "adds and removes columns" do
    create_dsl_probe(order: "device_id") { |t| t.integer :device_id }
    connection.add_column("dsl_probe", "extra", :string)
    expect(connection.column_exists?("dsl_probe", "extra")).to be(true)

    connection.remove_column("dsl_probe", "extra")
    expect(connection.column_exists?("dsl_probe", "extra")).to be(false)
  end

  it "drops tables with if_exists" do
    create_dsl_probe(order: "device_id") { |t| t.integer :device_id }
    connection.drop_table("dsl_probe", if_exists: true)
    expect(connection.table_exists?("dsl_probe")).to be(false)
  end
end
