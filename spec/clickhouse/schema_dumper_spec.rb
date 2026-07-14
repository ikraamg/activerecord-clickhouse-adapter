# frozen_string_literal: true

require "stringio"

RSpec.describe "ClickHouse schema dumper" do
  subject(:dump) do
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("dump_probe_events", if_exists: true)
    conn.create_table("dump_probe_events",
                      engine: "ReplacingMergeTree(ts)",
                      order: "(device_id, ts)",
                      partition: "toDate(ts)",
                      ttl: "toDateTime(ts) + toIntervalDay(30)",
                      settings: { index_granularity: 4096 }) do |t|
      t.integer :device_id, limit: 8
      t.datetime :ts, precision: 3, default: -> { "now64(3)" }
      t.string :kind, low_cardinality: true, default: "none"
      t.string :note, null: true
      t.decimal :amount, precision: 18, scale: 6
      t.column :tags, "Array(String)"
      t.column :uid, "UUID"
      t.index :note, name: "idx_note", using: "bloom_filter", granularity: 4
    end
    # Projections get their own plain MergeTree: ReplacingMergeTree refuses ADD
    # PROJECTION unless deduplicate_merge_projection_mode is loosened (code 344).
    conn.drop_table("dump_probe_readings", if_exists: true)
    conn.create_table("dump_probe_readings", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :kind
      t.integer :device_id, limit: 8
    end
    conn.add_projection("dump_probe_readings", "by_kind", order: "kind")
    conn.add_projection("dump_probe_readings", "daily_counts", select: "device_id, count()", group: "device_id")
    conn.execute("DROP DICTIONARY IF EXISTS dump_probe_labels")
    conn.execute("CREATE TABLE dump_probe_dims (id UInt64, label String) ENGINE = MergeTree ORDER BY id")
    conn.create_dictionary("dump_probe_labels", source: "dump_probe_dims", primary_key: :id,
                                                layout: :hashed, lifetime: 60..300)
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP DICTIONARY IF EXISTS dump_probe_labels")
    conn.drop_table("dump_probe_dims", if_exists: true)
    conn.drop_table("dump_probe_events", if_exists: true)
    conn.drop_table("dump_probe_readings", if_exists: true)
  end

  it "dumps the table with its ClickHouse options and no synthetic id" do
    expect(dump).to include(
      'create_table "dump_probe_events", id: false, engine: "ReplacingMergeTree(ts)", ' \
      'partition: "toDate(ts)", order: "(device_id, ts)", ' \
      'ttl: "toDateTime(ts) + toIntervalDay(30)", settings: {index_granularity: 4096}, ' \
      "force: :cascade do |t|"
    )
  end

  it "dumps sized integers with their limit" do
    expect(dump).to include('t.integer "device_id", limit: 8')
  end

  it "dumps datetime precision and function defaults" do
    expect(dump).to include('t.datetime "ts", precision: 3, default: -> { "now64(3)" }')
  end

  it "dumps LowCardinality as a column option" do
    expect(dump).to include('t.string "kind", default: "none", low_cardinality: true')
  end

  it "dumps Nullable columns with an explicit null: true" do
    expect(dump).to include('t.string "note", null: true')
  end

  it "dumps decimals with precision and scale" do
    expect(dump).to include('t.decimal "amount", precision: 18, scale: 6')
  end

  it "dumps composite types verbatim" do
    expect(dump).to include('t.column "tags", "Array(String)"')
  end

  it "dumps ClickHouse-only scalar types verbatim" do
    expect(dump).to include('t.column "uid", "UUID"')
  end

  it "dumps data-skipping indexes with type and granularity" do
    expect(dump).to include('t.index ["note"], name: "idx_note", using: "bloom_filter", granularity: 4')
  end

  it "dumps sort projections with their ORDER BY" do
    expect(dump).to include('add_projection "dump_probe_readings", "by_kind", select: "*", order: "kind"')
  end

  it "dumps aggregate projections with their GROUP BY" do
    expect(dump).to include(
      'add_projection "dump_probe_readings", "daily_counts", select: "device_id, count()", group: "device_id"'
    )
  end

  it "dumps dictionaries with source, key, layout and lifetime" do
    expect(dump).to include(
      'create_dictionary "dump_probe_labels", source: "dump_probe_dims", ' \
      'primary_key: "id", layout: :hashed, lifetime: 60..300'
    )
  end

  it "never leaks credentials into the dump" do
    expect(dump).not_to match(/PASSWORD|USER '/)
  end

  context "when the dump is loaded back and re-dumped" do
    def isolated_dump
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
    end

    around do |example|
      ActiveRecord::SchemaDumper.ignore_tables = [/\A(?!dump_probe_(?:events|readings)\z)/]
      example.run
    ensure
      ActiveRecord::SchemaDumper.ignore_tables = []
    end

    it "round-trips byte-identically" do
      first_dump = isolated_dump
      ActiveRecord::Base.lease_connection.drop_table("dump_probe_events")
      ActiveRecord::Base.lease_connection.drop_table("dump_probe_readings")
      eval(first_dump) # rubocop:disable Security/Eval -- loading the dump is the point
      expect(isolated_dump).to eq(first_dump)
    end
  end
end
