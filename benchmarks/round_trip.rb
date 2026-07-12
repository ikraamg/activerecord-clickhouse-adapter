# frozen_string_literal: true

# Round-trip performance baseline for the adapter's hot paths, against the live server.
#
#   bundle exec ruby benchmarks/round_trip.rb
#
# Results are recorded in benchmarks/BASELINE.md; regenerate after any change to the
# read path (HTTPConnection#parse, Types casters, cast_result) or the write path.
require "activerecord-clickhouse-adapter"
require "benchmark/ips"
require "memory_profiler"

ActiveRecord::Base.establish_connection(
  adapter: "clickhouse",
  host: ENV.fetch("CLICKHOUSE_HOST", "localhost"),
  port: Integer(ENV.fetch("CLICKHOUSE_HTTP_PORT", 18_123)),
  username: ENV.fetch("CLICKHOUSE_USER", "rails"),
  password: ENV.fetch("CLICKHOUSE_PASSWORD", "rails"),
  database: ENV.fetch("CLICKHOUSE_DATABASE", "ar_clickhouse_test")
)

connection = ActiveRecord::Base.lease_connection

connection.drop_table("bench_events", if_exists: true)
connection.create_table("bench_events", order: "(device_id, ts)") do |t|
  t.integer :device_id, limit: 8
  t.datetime :ts, precision: 3
  t.string :event_type, low_cardinality: true
  t.decimal :amount, precision: 18, scale: 6
  t.float :ratio
end
connection.execute(<<~SQL)
  INSERT INTO bench_events
  SELECT number % 100, now64(3) - number, ['render', 'serve', 'checkin'][(number % 3) + 1],
         toDecimal64(number, 6) / 7, number / 3.0
  FROM numbers(100000)
SQL

insert_batch = Array.new(1_000) do |n|
  { device_id: n, ts: Time.now.utc, event_type: "bench", amount: "#{n}.123456", ratio: n / 7.0 }
end
model = Class.new(ActiveRecord::Base) do
  self.table_name = "bench_events"

  def self.name = "BenchEvent"
end

puts "ClickHouse #{connection.database_version} / Ruby #{RUBY_VERSION} / AR #{ActiveRecord::VERSION::STRING}"

Benchmark.ips do |bench|
  bench.report("select_all 10k rows x5 cols (typed)") do
    connection.select_all("SELECT * FROM bench_events LIMIT 10000")
  end
  bench.report("pluck 100k Int64") { model.limit(100_000).pluck(:device_id) }
  bench.report("aggregate 100k rows server-side") { model.sum(:amount) }
  bench.report("insert_all! 1k rows") { model.insert_all!(insert_batch) }
end

report = MemoryProfiler.report { connection.select_all("SELECT * FROM bench_events LIMIT 10000") }
puts format("select_all 10k rows: %<megabytes>.1f MB allocated, %<objects>d objects",
            megabytes: report.total_allocated_memsize / 1024.0 / 1024.0, objects: report.total_allocated)

connection.drop_table("bench_events", if_exists: true)
