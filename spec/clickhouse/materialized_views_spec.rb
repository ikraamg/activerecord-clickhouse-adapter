# frozen_string_literal: true

require "stringio"

# The core OLAP idiom: ingest raw rows, read pre-aggregated ones. A materialized view
# with a TO target is ClickHouse's insert trigger; inner-storage MVs (no TO) and
# POPULATE are deliberately unsupported — both are documented footguns.
RSpec.describe "ClickHouse materialized views" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("mv_probe_daily", if_exists: true)
    conn.drop_table("mv_probe_raw", if_exists: true)
    conn.create_table("mv_probe_raw", order: "device_id") do |t|
      t.integer :device_id, limit: 8
      t.integer :duration_ms, limit: 8
      t.datetime :created_at, precision: 6
    end
    conn.create_table("mv_probe_daily", engine: "SummingMergeTree", order: "(day, device_id)") do |t|
      t.date :day
      t.integer :device_id, limit: 8
      t.integer :total_ms, limit: 8
    end
    conn.create_materialized_view("mv_probe_rollup", to: "mv_probe_daily", as: <<~SQL.squish)
      SELECT toDate(created_at) AS day, device_id, sum(duration_ms) AS total_ms
      FROM mv_probe_raw GROUP BY day, device_id
    SQL
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_materialized_view("mv_probe_rollup", if_exists: true)
    conn.drop_table("mv_probe_daily", if_exists: true)
    conn.drop_table("mv_probe_raw", if_exists: true)
  end

  before do
    connection.execute("TRUNCATE TABLE mv_probe_raw")
    connection.execute("TRUNCATE TABLE mv_probe_daily")
  end

  it "routes inserts through the view into the target table" do
    connection.execute(<<~SQL.squish)
      INSERT INTO mv_probe_raw VALUES (1, 100, '2026-07-13 01:00:00'), (1, 50, '2026-07-13 02:00:00')
    SQL
    expect(connection.select_value("SELECT sum(total_ms) FROM mv_probe_daily")).to eq(150)
  end

  it "lists the view among views, not tables" do
    expect(connection.views).to include("mv_probe_rollup")
  end

  it "keeps materialized views out of tables" do
    expect(connection.tables).not_to include("mv_probe_rollup")
  end

  it "raises when the target is missing (inner-storage views are unsupported)" do
    expect { connection.create_materialized_view("mv_probe_bad", as: "SELECT 1") }
      .to raise_error(ArgumentError, /to:/)
  end

  describe "drop_materialized_view" do
    it "removes the view" do
      connection.create_materialized_view("mv_probe_temp", to: "mv_probe_daily", as: <<~SQL.squish)
        SELECT toDate(created_at) AS day, device_id, sum(duration_ms) AS total_ms
        FROM mv_probe_raw GROUP BY day, device_id
      SQL
      connection.drop_materialized_view("mv_probe_temp")
      expect(connection.views).not_to include("mv_probe_temp")
    end

    it "tolerates a missing view with if_exists" do
      expect { connection.drop_materialized_view("mv_probe_ghost", if_exists: true) }
        .not_to raise_error
    end
  end

  describe "schema dumping" do
    subject(:dump) do
      ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
    end

    it "dumps the view with its target" do
      expect(dump).to include('create_materialized_view "mv_probe_rollup", to: "mv_probe_daily"')
    end

    it "dumps the SELECT without database qualifiers" do
      expect(dump).to include("FROM mv_probe_raw GROUP BY day, device_id")
    end

    it "dumps views after all tables so targets exist on load" do
      expect(dump.index("create_materialized_view")).to be > dump.rindex("create_table")
    end

    context "when the dump is loaded back and re-dumped" do
      around do |example|
        ActiveRecord::SchemaDumper.ignore_tables = [/\A(?!mv_probe)/]
        example.run
      ensure
        ActiveRecord::SchemaDumper.ignore_tables = []
      end

      def isolated_dump
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
      end

      it "round-trips byte-identically" do
        first_dump = isolated_dump
        connection.drop_materialized_view("mv_probe_rollup")
        connection.drop_table("mv_probe_daily")
        connection.drop_table("mv_probe_raw")
        eval(first_dump) # rubocop:disable Security/Eval -- loading the dump is the point
        expect(isolated_dump).to eq(first_dump)
      end
    end
  end
end
