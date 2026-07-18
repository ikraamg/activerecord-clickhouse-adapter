# frozen_string_literal: true

require "stringio"

# ClickHouse DDL the storage layer actually tunes: per-column compression codecs,
# MATERIALIZED/ALIAS server-computed columns, a PRIMARY KEY narrower than the sorting
# key, and SAMPLE BY. Each must survive create_table -> schema.rb -> reload.
RSpec.describe "ClickHouse DDL fidelity" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("ddl_fidelity_probe", if_exists: true)
    conn.create_table("ddl_fidelity_probe",
                      order: "(id, sipHash64(id), stamped)",
                      primary_key: "(id, sipHash64(id))",
                      sample: "sipHash64(id)") do |t|
      t.integer :id, limit: 8
      t.string :payload, codec: "ZSTD(3)"
      t.datetime :stamped, precision: 3
      t.datetime :hour, precision: 3, materialized: "toStartOfHour(stamped)"
      t.integer :doubled, limit: 8, alias: "id * 2"
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("ddl_fidelity_probe", if_exists: true)
  end

  describe "server-computed columns" do
    # Inserted per example: the round-trip spec recreates the table empty, and
    # example order is randomized.
    before do
      connection.execute("TRUNCATE TABLE ddl_fidelity_probe")
      connection.execute("INSERT INTO ddl_fidelity_probe (id, payload, stamped) VALUES (1, 'x', '2026-07-13 10:30:00')")
    end

    it "computes MATERIALIZED columns on insert" do
      expect(connection.select_value("SELECT hour FROM ddl_fidelity_probe")).to eq(Time.utc(2026, 7, 13, 10))
    end

    it "computes ALIAS columns at read time" do
      expect(connection.select_value("SELECT doubled FROM ddl_fidelity_probe")).to eq(2)
    end

    it "stores the codec on the column" do
      codec = connection.select_value(<<~SQL.squish)
        SELECT compression_codec FROM system.columns
        WHERE database = currentDatabase() AND table = 'ddl_fidelity_probe' AND name = 'payload'
      SQL
      expect(codec).to eq("CODEC(ZSTD(3))")
    end

    it "refuses a default alongside materialized (server would too, less clearly)" do
      expect do
        connection.create_table("ddl_fidelity_bad", order: "id") do |t|
          t.integer :id, limit: 8
          t.integer :x, default: 1, materialized: "id"
        end
      end.to raise_error(ArgumentError, /materialized/)
    end
  end

  describe "table clauses" do
    it "records the narrower primary key" do
      expect(connection.select_value(<<~SQL.squish)).to eq("id, sipHash64(id)")
        SELECT primary_key FROM system.tables
        WHERE database = currentDatabase() AND name = 'ddl_fidelity_probe'
      SQL
    end

    it "records the sampling key" do
      expect(connection.select_value(<<~SQL.squish)).to eq("sipHash64(id)")
        SELECT sampling_key FROM system.tables
        WHERE database = currentDatabase() AND name = 'ddl_fidelity_probe'
      SQL
    end

    it "answers table_options with primary_key and sample" do
      expect(connection.table_options("ddl_fidelity_probe"))
        .to include(primary_key: "(id, sipHash64(id))", sample: "sipHash64(id)")
    end
  end

  # Rails' composite-key convention: primary_key: as an array of column names.
  # ClickHouse takes it as a PRIMARY KEY tuple and infers ORDER BY from it
  # (probed live: ORDER BY may be omitted when PRIMARY KEY is given).
  describe "Rails-style composite primary_key arrays" do
    before do
      connection.create_table("ddl_composite_probe", primary_key: %w[region code], force: true) do |t|
        t.string :region
        t.integer :code
      end
    end

    after { connection.drop_table("ddl_composite_probe", if_exists: true) }

    it "renders the array as a PRIMARY KEY tuple" do
      expect(server_key("primary_key")).to eq("region, code")
    end

    it "lets the server infer the sorting key from the primary key" do
      expect(server_key("sorting_key")).to eq("region, code")
    end

    def server_key(kind)
      connection.select_value(<<~SQL.squish)
        SELECT #{kind} FROM system.tables
        WHERE database = currentDatabase() AND name = 'ddl_composite_probe'
      SQL
    end
  end

  describe "schema dumping" do
    subject(:dump) do
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
    end

    it "dumps primary_key and sample table options" do
      expect(dump).to include('primary_key: "(id, sipHash64(id))"', 'sample: "sipHash64(id)"')
    end

    it "dumps column codecs" do
      expect(dump).to include('t.string "payload", codec: "ZSTD(3)"')
    end

    it "dumps materialized columns with their expression" do
      expect(dump).to include('t.datetime "hour", precision: 3, materialized: "toStartOfHour(stamped)"')
    end

    it "dumps alias columns with their expression" do
      expect(dump).to include('t.integer "doubled", limit: 8, alias: "id * 2"')
    end

    context "when the dump is loaded back and re-dumped" do
      around do |example|
        ActiveRecord::SchemaDumper.ignore_tables = [/\A(?!ddl_fidelity_probe\z)/]
        example.run
      ensure
        ActiveRecord::SchemaDumper.ignore_tables = []
      end

      def isolated_dump
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
      end

      it "round-trips byte-identically" do
        first_dump = isolated_dump
        connection.drop_table("ddl_fidelity_probe")
        eval(first_dump) # rubocop:disable Security/Eval -- loading the dump is the point
        expect(isolated_dump).to eq(first_dump)
      end
    end
  end
end
