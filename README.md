# activerecord-clickhouse-adapter

A fully featured Active Record adapter for [ClickHouse](https://clickhouse.com)

- Native types on every read — `Decimal`, `DateTime64`, `Enum`, `Array`, `Map`, `Tuple`, `IPv4/6`, `UUID`, and more
- Server-side bind parameters, never string interpolation
- MergeTree-aware migrations, `schema.rb`, and `structure.sql`
- OLAP query surface: `FINAL`, `PREWHERE`, `SAMPLE`, `LIMIT BY`, time bucketing, approximate aggregates
- Real instrumentation: rows read, bytes read, and server elapsed time on every query
- Fast wire: RowBinary reads and chunked streaming inserts

Tested against a live ClickHouse server only — no mocked responses, ever.

**Status: pre-1.0, under active development.** See [PLAN.md](PLAN.md) for architecture and roadmap.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "activerecord-clickhouse-adapter"
```

Requires Active Record 8.1+, Ruby 3.2+, and ClickHouse 25.8+ (each LTS from 25.8 through `latest` runs in CI).

## Getting Started

Add a ClickHouse database to `config/database.yml`:

```yaml
production:
  primary:
    # ... your existing database ...
  clickhouse:
    adapter: clickhouse
    host: localhost
    port: 8123
    database: analytics_production
    username: rails
    password: <%= ENV["CLICKHOUSE_PASSWORD"] %>
    migrations_paths: db/migrate_clickhouse
```

Create an abstract base class on its own pool:

```ruby
class AnalyticsRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :clickhouse, reading: :clickhouse }
end
```

Define models as usual:

```ruby
class Event < AnalyticsRecord
  include ActiveRecord::ConnectionAdapters::ClickHouse::Querying
end
```

The `Querying` concern is optional. It adds the ClickHouse relation methods below.

## Migrations

Tables default to `id: false` — ClickHouse has no autoincrement. The sorting key (`order:`) is required:

```ruby
create_table :events, order: "(device_id, ts)", partition: "toDate(ts)", ttl: "toDateTime(ts) + INTERVAL 30 DAY" do |t|
  t.integer  :device_id, limit: 8
  t.datetime :ts, precision: 3, default: -> { "now64(3)" }
  t.string   :event_type, low_cardinality: true, default: ""
  t.integer  :duration_ms, null: true
end
```

Columns are non-nullable by default, matching ClickHouse. Use `null: true` for `Nullable(...)`.

The full alter surface works on existing tables — `rename_column`, `change_column`, `change_column_null` (with the Rails backfill default), `change_column_default`, `change_column_comment`, `change_table_comment`, and `add_index`/`remove_index` for data-skipping indexes. `create_join_table` defaults its sorting key to the two reference columns.

ClickHouse-specific column options:

```ruby
t.string  :status, low_cardinality: true
t.integer :bytes, codec: "Delta, ZSTD"
t.date    :day, materialized: "toDate(ts)"
t.string  :upper_status, alias: "upper(status)"
```

Engines, projections, and materialized views:

```ruby
create_table :daily_counts, engine: "SummingMergeTree", order: "day"

create_materialized_view :events_to_daily, to: "daily_counts", as: "SELECT toDate(ts) AS day, count() AS n FROM events GROUP BY day"

add_projection :events, :by_type, order: "event_type"
materialize_projection :events, :by_type
optimize_table :events
```

Partition lifecycle:

```ruby
partitions :events            # => ["20260701", "20260702", ...]
detach_partition :events, "20260701"
attach_partition :events, "20260701"
drop_partition :events, "20260701"
```

Dictionaries replace star-schema dimension JOINs with in-memory lookups. Columns are inferred from the source table, and the adapter's credentials are injected into the SOURCE clause:

```ruby
create_dictionary :device_names, source: "devices", primary_key: :id
create_dictionary :device_names, source: "devices", primary_key: :id, layout: :hashed, lifetime: 60..300
create_dictionary :device_names, source: "devices", database: "dimensions", primary_key: :id
reload_dictionary :device_names
drop_dictionary :device_names, if_exists: true
```

Dictionaries round-trip through `schema.rb` (as `create_dictionary` calls that re-infer columns and re-inject credentials on load) and `structure.sql` (credentials are masked in the file and swapped back in by `db:schema:load`).

Set `cluster:` in `database.yml` to stamp schema DDL with `ON CLUSTER`, sending it through the distributed DDL queue:

```yaml
production:
  adapter: clickhouse
  cluster: my_cluster
```

Both `schema.rb` and `structure.sql` round-trip engines, sorting keys, partitions, TTLs, codecs, settings, and projections (dumped as `add_projection` statements).

## Querying

Standard Active Record works as expected:

```ruby
Event.where(device_id: 42).order(:ts).limit(10)
Event.group(:event_type).count
Event.where("duration_ms > ?", 100).average(:duration_ms)
```

ClickHouse dialect methods (via the `Querying` concern):

```ruby
Event.final                          # FROM events FINAL
Event.sample(0.1)                    # SAMPLE 0.1
Event.prewhere(device_id: 42)        # PREWHERE, before WHERE
Event.limit_by(1, :device_id)        # LIMIT 1 BY device_id
Event.settings(max_threads: 8)       # SETTINGS max_threads = 8
Event.array_join(:tags, as: :tag)    # one row per array element
```

Time series:

```ruby
Event.group_by_period(:hour, :ts).count            # chronological buckets
Event.group_by_period(:day, :ts).fill.count        # gap-filled with WITH FILL
Event.group(:device_id).rollup.count               # totals row, keyed nil
```

Window functions project alongside the row:

```ruby
Event.window(:row_number, as: :position, partition_by: :device_id, order_by: :ts)
Event.window(:sum, :duration_ms, as: :running_total, order_by: :ts)
Event.window(:lag, :battery, as: :previous, partition_by: :device_id, order_by: :ts,
             frame: "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")
```

Dictionary lookups project alongside the row:

```ruby
Event.dict_get(:device_names, :name, key: :device_id)                     # ... AS name
Event.dict_get(:device_names, :name, key: :device_id, as: :device_name)
Event.dict_get(:device_names, :name, key: :device_id, default: "unknown") # dictGetOrDefault
```

Approximate and positional aggregates:

```ruby
Event.uniq_count(:device_id)                 # uniq() — fast, approximate
Event.uniq_count(:device_id, exact: true)    # uniqExact()
Event.quantile(0.95, :duration_ms)           # p95
Event.top_k(10, :event_type)                 # most frequent values
Event.arg_max(:event_type, :ts)              # value at max ts
Event.estimated_count                        # O(1) row estimate from metadata
```

All aggregates accept `if:` for conditional aggregation in one scan:

```ruby
Event.quantile(0.95, :duration_ms, if: { event_type: "render" })
```

`AggregateFunction` state columns merge with `merge: true`:

```ruby
DailyRollup.group(:day).uniq_count(:visitors_state, merge: true)
```

## Writing Data

Single-row writes work, but ClickHouse wants batches:

```ruby
Event.insert_all!(rows)     # one INSERT statement
Event.insert_all(rows)      # same — with no unique constraints, nothing can conflict
```

Stream any Enumerable without materializing it:

```ruby
Event.insert_stream(rows)   # one chunked HTTP request, lazy enumerators welcome
```

Updates and deletes become mutations (`ALTER TABLE ... UPDATE / DELETE`):

```ruby
Event.where(device_id: 42).update_all(event_type: "gone")
Event.where(device_id: 42).delete_all
```

Sorting-key columns cannot be updated. `upsert_all` raises — use a `ReplacingMergeTree` or `SummingMergeTree` engine instead.

For high-frequency small inserts, enable server-side batching:

```yaml
clickhouse:
  adapter: clickhouse
  async_insert: true
```

## Instrumentation

Every query's `sql.active_record` notification carries server statistics:

```ruby
ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  stats = event.payload[:clickhouse]
  # => { query_id:, read_rows:, read_bytes:, written_rows:, elapsed_ns: }
end
```

`explain` supports ClickHouse variants:

```ruby
Event.where(device_id: 42).explain             # EXPLAIN
Event.where(device_id: 42).explain(:pipeline)  # EXPLAIN PIPELINE
Event.where(device_id: 42).explain(:indexes)   # EXPLAIN indexes = 1
```

## Connection Options

```yaml
clickhouse:
  adapter: clickhouse
  host: localhost
  port: 8123
  database: analytics_production
  username: rails
  password: secret
  ssl: true                # HTTPS to the server
  ssl_verify: false        # escape hatch for self-signed certificates (default: verify)
  connect_timeout: 5
  read_timeout: 60
  write_timeout: 60
  compression: true        # gzip responses (default: on)
  join_use_nulls: 1        # SQL-standard outer-join NULLs (default: on)
  mutations_sync: 1        # block until mutations apply (default: async)
  async_insert: false      # server-side insert batching
  select_format: binary    # RowBinary reads; use `json` to force the JSON wire
```

## Semantics Worth Knowing

- **No transactions.** ClickHouse has none; `transaction` blocks run their contents without BEGIN/COMMIT and cannot roll back.
- **Primary keys are client-generated.** Tables with a single-column integer or UUID sorting key get time-ordered ids (Snowflake-style / UUIDv7) assigned before INSERT.
- **Mutation counts are best-effort.** `update_all`/`delete_all` return a pre-mutation `SELECT count()` — ClickHouse reports no affected-row counts.
- **Eventual merges.** `ReplacingMergeTree` deduplicates at merge time; read with `.final` when you need collapsed rows.

## Development

Everything runs against a real ClickHouse server:

```sh
docker compose up -d --wait
bundle install
bundle exec rspec
bundle exec rubocop
```

Run against Rails main:

```sh
RAILS_SOURCE=edge bundle install
RAILS_SOURCE=edge bundle exec rspec
```

The suite includes a Rails compatibility harness that runs vendored upstream Active Record test suites (~1,600 tests) against the adapter. See `spec/rails_compat/`.

## History

View the [changelog](CHANGELOG.md).

## Contributing

Everyone is encouraged to help improve this project. Here are a few ways you can help:

- [Report bugs](https://github.com/ikraamg/activerecord-clickhouse-adapter/issues)
- Fix bugs and [submit pull requests](https://github.com/ikraamg/activerecord-clickhouse-adapter/pulls)
- Write, clarify, or fix documentation
- Suggest or add new features
