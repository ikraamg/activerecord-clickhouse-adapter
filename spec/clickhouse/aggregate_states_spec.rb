# frozen_string_literal: true

# The aggregate-state pipeline (Plausible/Metrica's core pattern): raw events flow
# through a materialized view computing -State combinators into an AggregatingMergeTree
# table; reads finish the aggregation with -Merge. States are opaque server-side binary;
# the argument type is invariant (CANNOT_CONVERT_TYPE, code 70 — probed 2026-07-13).
RSpec.describe "ClickHouse aggregate states" do
  subject(:stats_model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "agg_state_daily"

      def self.name = "AggStateDaily"
    end
  end

  let(:events_model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "agg_state_events"

      def self.name = "AggStateEvent"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_materialized_view("agg_state_rollup", if_exists: true)
    conn.drop_table("agg_state_daily", if_exists: true)
    conn.drop_table("agg_state_events", if_exists: true)
    conn.create_table("agg_state_events", order: "(visitor_id, created_at)") do |t|
      t.integer :visitor_id, limit: 8
      t.integer :duration_ms, limit: 8
      t.datetime :created_at, precision: 6
    end
    conn.create_table("agg_state_daily", engine: "AggregatingMergeTree", order: "day") do |t|
      t.date :day
      t.column :visitors, "AggregateFunction(uniq, Int64)"
      t.column :p95_duration, "AggregateFunction(quantile(0.95), Int64)"
      t.column :total_ms, "SimpleAggregateFunction(sum, Int64)"
    end
    conn.create_materialized_view("agg_state_rollup", to: "agg_state_daily", as: <<~SQL.squish)
      SELECT toDate(created_at) AS day,
             uniqState(visitor_id) AS visitors,
             quantileState(0.95)(duration_ms) AS p95_duration,
             sum(duration_ms) AS total_ms
      FROM agg_state_events GROUP BY day
    SQL
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_materialized_view("agg_state_rollup", if_exists: true)
    conn.drop_table("agg_state_daily", if_exists: true)
    conn.drop_table("agg_state_events", if_exists: true)
  end

  before do
    connection = ActiveRecord::Base.lease_connection
    connection.execute("TRUNCATE TABLE agg_state_events")
    connection.execute("TRUNCATE TABLE agg_state_daily")
    events_model.insert_all!([
                               { visitor_id: 1, duration_ms: 100, created_at: Time.utc(2026, 7, 13, 8) },
                               { visitor_id: 1, duration_ms: 200, created_at: Time.utc(2026, 7, 13, 9) },
                               { visitor_id: 2, duration_ms: 50, created_at: Time.utc(2026, 7, 13, 10) },
                               { visitor_id: 3, duration_ms: 40, created_at: Time.utc(2026, 7, 14, 8) }
                             ])
  end

  describe "merged terminal reads" do
    it "finishes uniq states with uniq_count(merge: true)" do
      expect(stats_model.uniq_count(:visitors, merge: true)).to eq(3)
    end

    it "finishes quantile states with quantile(merge: true)" do
      expect(stats_model.quantile(0.95, :p95_duration, merge: true)).to be_within(20).of(185)
    end

    it "scopes merged reads through where" do
      expect(stats_model.where(day: Date.new(2026, 7, 14)).uniq_count(:visitors, merge: true)).to eq(1)
    end

    it "sums SimpleAggregateFunction columns with plain Rails sum" do
      expect(stats_model.sum(:total_ms)).to eq(390)
    end
  end

  describe "grouped merged reads" do
    it "returns a hash keyed by the group when merging per bucket" do
      series = stats_model.group(:day).uniq_count(:visitors, merge: true)
      expect(series[Date.new(2026, 7, 13)]).to eq(2)
    end

    it "keys multi-column groups by arrays" do
      raw_events = Class.new(ActiveRecord::Base) do
        include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

        self.table_name = "agg_state_events"

        def self.name = "AggStateEventGrouped"
      end
      counts = raw_events.group(:visitor_id, :duration_ms).uniq_count(:created_at)
      expect(counts[[1, 100]]).to eq(1)
    end

    it "composes with group_by_period" do
      series = stats_model.group_by_period(:day, :day).uniq_count(:visitors, merge: true)
      expect(series.values).to eq([2, 1])
    end

    it "groups plain (non-merge) aggregates too" do
      raw = Class.new(ActiveRecord::Base) do
        include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

        self.table_name = "agg_state_events"

        def self.name = "AggStateEventOlap"
      end
      expect(raw.group_by_period(:day, :created_at).uniq_count(:visitor_id).values).to eq([2, 1])
    end
  end

  describe "state columns on the wire" do
    it "casts SimpleAggregateFunction columns to their inner type" do
      expect(stats_model.first.total_ms).to be_a(Integer)
    end

    it "passes opaque AggregateFunction state binary through without raising" do
      expect(stats_model.first.visitors).to be_a(String)
    end

    it "survives a merge after parts are optimized together" do
      ActiveRecord::Base.lease_connection.optimize_table("agg_state_daily")
      expect(stats_model.uniq_count(:visitors, merge: true)).to eq(3)
    end
  end

  describe "schema dumping" do
    it "dumps AggregateFunction columns verbatim" do
      dump = ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
      expect(dump).to include('t.column "visitors", "AggregateFunction(uniq, Int64)"')
    end
  end
end
