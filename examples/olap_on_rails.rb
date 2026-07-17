# frozen_string_literal: true

# OLAP on Rails — a runnable tour of this adapter's ClickHouse-native surface.
#
#   docker compose up -d --wait
#   bundle exec ruby examples/olap_on_rails.rb
#
# The domain is web analytics: raw page views land in a MergeTree fact table,
# a materialized view folds them into an AggregatingMergeTree rollup as they
# arrive, and a dictionary replaces the site-dimension JOIN. Everything below
# is plain Active Record — models, migration-style DDL, relations — with the
# OLAP idioms expressed through the adapter's relation and schema extensions.

require "active_record"
require_relative "../lib/activerecord-clickhouse-adapter"

ActiveRecord::Base.establish_connection(
  adapter: "clickhouse",
  host: ENV.fetch("CLICKHOUSE_HOST", "localhost"),
  port: Integer(ENV.fetch("CLICKHOUSE_HTTP_PORT", 18_123)),
  username: ENV.fetch("CLICKHOUSE_USER", "rails"),
  password: ENV.fetch("CLICKHOUSE_PASSWORD", "rails"),
  database: ENV.fetch("CLICKHOUSE_DATABASE", "ar_clickhouse_test")
)

def banner(title)
  puts "", "== #{title} " + ("=" * [60 - title.length, 0].max)
end

connection = ActiveRecord::Base.lease_connection

# --- Schema ------------------------------------------------------------------
# The fact table: partitioned by month, sorted by (site_id, ts) so per-site
# time-range scans prune to a handful of granules. No autoincrement id — the
# sorting key is the physical identity, which is the OLAP norm.
banner "Schema: fact table, dimension, dictionary, rollup"

connection.drop_materialized_view("page_views_to_daily", if_exists: true)
%w[daily_site_stats page_views sites].each { |table| connection.drop_table(table, if_exists: true) }
connection.drop_dictionary("site_names", if_exists: true)

connection.create_table :page_views, order: "(site_id, ts)", partition: "toYYYYMM(ts)" do |t|
  t.integer :site_id, limit: 8
  t.datetime :ts, precision: 3
  t.string :path, low_cardinality: true
  t.integer :visitor_id, limit: 8
  t.integer :load_ms, limit: 4
end

# A dimension table plus a dictionary over it: dictGet is an in-memory lookup,
# so queries never JOIN the dimension. ReplacingMergeTree makes the dimension
# mutable OLAP-style: re-insert the row and the engine collapses versions at
# merge time — reads that need collapsed-now use .final.
connection.create_table :sites, engine: "ReplacingMergeTree", order: "id" do |t|
  t.integer :id, limit: 8
  t.string :name
end
connection.create_dictionary :site_names, source: :sites, primary_key: :id, layout: :flat

# The pre-aggregation pipeline: an AggregatingMergeTree target holding partial
# aggregate states, fed by a materialized view that fires on every insert into
# page_views. Reads finish the states with merge: true — no batch jobs.
connection.create_table :daily_site_stats, engine: "AggregatingMergeTree", order: "(site_id, day)" do |t|
  t.integer :site_id, limit: 8
  t.date :day
  t.column :visitors, "AggregateFunction(uniq, Int64)"
  t.column :views, "SimpleAggregateFunction(sum, UInt64)"
end
connection.create_materialized_view "page_views_to_daily", to: "daily_site_stats", as: <<~SQL.squish
  SELECT site_id, toDate(ts) AS day, uniqState(visitor_id) AS visitors, toUInt64(count()) AS views
  FROM page_views GROUP BY site_id, day
SQL

puts "created: page_views (MergeTree), sites + site_names dictionary,"
puts "         daily_site_stats (AggregatingMergeTree) <- page_views_to_daily MV"

# --- Models ------------------------------------------------------------------
# Querying is the single include that adds the ClickHouse relation surface.
class Site < ActiveRecord::Base
  include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

  self.primary_key = "id"
end

class PageView < ActiveRecord::Base
  include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

  self.primary_key = nil
end

class DailySiteStat < ActiveRecord::Base
  include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

  self.table_name = "daily_site_stats"
  self.primary_key = nil
end

# --- Ingestion ---------------------------------------------------------------
banner "Ingestion: insert_all! and insert_stream"

Site.create!(id: 1, name: "blog")
Site.create!(id: 2, name: "docs")
connection.reload_dictionary("site_names")

# insert_all! renders one multi-row INSERT — fine for small batches.
PageView.insert_all!(
  (0...500).map do |n|
    { site_id: 1 + (n % 2), ts: Time.utc(2026, 7, 1) + (n * 600), path: "/page/#{n % 7}",
      visitor_id: 100 + (n % 50), load_ms: 40 + ((n * 37) % 400) }
  end
)

# insert_stream sends rows as one chunked HTTP body (RowBinary framing on the
# wire) without building a giant SQL string — lazy enumerators welcome.
july_15 = Time.utc(2026, 7, 15)
PageView.insert_stream(
  (0...10_000).lazy.map do |n|
    { site_id: 1 + (n % 2), ts: july_15 + (n * 60), path: "/page/#{n % 7}",
      visitor_id: 100 + (n % 300), load_ms: 35 + ((n * 53) % 900) }
  end
)

puts "ingested #{PageView.count} page views (500 via insert_all!, 10,000 via insert_stream)"

# --- The query tour ----------------------------------------------------------
banner "PREWHERE, LIMIT BY, SETTINGS"

# prewhere filters before column reads; limit_by is per-group top-N; settings
# ride the query. This is one SQL statement, no subqueries.
latest_per_site = PageView
                  .prewhere("load_ms > 100")
                  .limit_by(1, :site_id)
                  .order(ts: :desc)
                  .settings(max_execution_time: 10)
                  .pluck(:site_id, :path)
puts "slowest-filtered latest view per site: #{latest_per_site.inspect}"

banner "Time bucketing: group_by_period + fill"

# group_by_period buckets chronologically; fill plugs gaps server-side.
per_day = PageView.where(site_id: 1).group_by_period(:day, :ts).count
puts "site 1 daily views: #{per_day.transform_keys(&:to_s).inspect}"

banner "Approximate + conditional aggregates"

stats = {
  visitors_estimate: PageView.uniq_count(:visitor_id),
  visitors_exact: PageView.uniq_count(:visitor_id, exact: true),
  p95_load_ms: PageView.quantile(0.95, :load_ms),
  top_paths: PageView.top_k(3, :path),
  slow_views: PageView.uniq_count(:visitor_id, if: "load_ms > 500"),
  worst_path: PageView.arg_max(:path, :load_ms)
}
stats.each { |name, value| puts "#{name}: #{value.inspect}" }

banner "ROLLUP and window functions"

rollup = PageView.group(:site_id).rollup.count
puts "views by site with grand total (nil key): #{rollup.inspect}"

running = PageView
          .where(site_id: 1, ts: july_15...(july_15 + 300))
          .window(:row_number, as: :n, partition_by: :site_id, order_by: :ts)
          .select(:ts, :load_ms)
          .order(:ts)
          .limit(3)
puts "first rows with window row_number:"
running.each { |row| puts "  n=#{row[:n]} ts=#{row.ts} load_ms=#{row.load_ms}" }

banner "Dictionary lookups: dict_get instead of JOIN"

named = PageView.group(:site_id).order(:site_id).dict_get(:site_names, :name, key: :site_id).count(:visitor_id)
puts "views per site_id (dictGet renders the name in SELECT): #{named.inspect}"
sample = PageView.dict_get(:site_names, :name, key: :site_id, as: :site_name).order(:ts).first
puts "sample row: #{sample.site_name.inspect}"

banner "Mutable dimensions: ReplacingMergeTree + final"

# The OLAP update: re-insert the row. The engine keeps the newest version per
# sorting key at merge time; .final collapses versions at read time.
Site.create!(id: 1, name: "engineering blog")
connection.reload_dictionary("site_names")
puts "site rows without final: #{Site.where(id: 1).count} (both versions still in parts)"
puts "site 1 with final: #{Site.final.find(1).name.inspect}"

# --- Reading the pre-aggregation --------------------------------------------
banner "Aggregate-state pipeline: merge: true"

# The MV computed partial states on every insert; merge: true finishes them.
# Summing 10,500 raw rows never happens at read time.
day_one = DailySiteStat.where(site_id: 1, day: Date.new(2026, 7, 1))
puts "site 1, Jul 1 — visitors (uniqMerge): #{day_one.uniq_count(:visitors, merge: true)}"
puts "site 1, Jul 1 — views (sum of SimpleAggregateFunction): #{day_one.sum(:views)}"

# --- Operations --------------------------------------------------------------
banner "Partitions and EXPLAIN"

puts "partitions: #{connection.partitions("page_views").inspect}"
puts "dropping 202607 would be the OLAP bulk delete: connection.drop_partition(:page_views, '202607')"
puts PageView.where(site_id: 1).explain(:indexes).inspect.lines.grep(/PrimaryKey|Condition|Granules/).map(&:strip)

banner "Instrumentation: server stats on every query"

payloads = []
callback = ->(event) { payloads << event.payload[:clickhouse] }
ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { PageView.sum(:load_ms) }
puts "sql.active_record payload[:clickhouse]: #{payloads.last.inspect}"

# --- Cleanup -----------------------------------------------------------------
connection.drop_materialized_view("page_views_to_daily", if_exists: true)
connection.drop_dictionary("site_names", if_exists: true)
%w[daily_site_stats page_views sites].each { |table| connection.drop_table(table, if_exists: true) }
puts "", "done (schema cleaned up)"
