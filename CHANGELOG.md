# 0.2.0 (2026-07-23)

Breaking-ish (schema diff noise, not data changes):

- Updated `t.datetime` to default to precision 6 (microseconds, Rails' convention) —
  previously an unqualified datetime rendered `DateTime64(3)`. Existing consumer
  schemas diff as `DateTime64(3)` → `DateTime64(6)`; declare `precision: 3` to keep
  the old shape
- Fixed decimal DDL bounds: `precision:` without `scale:` now means scale 0 (the old
  `Decimal(N, 10)` shape was invalid for N < 10), and `scale:` without `precision:`
  raises the same `ArgumentError` as Rails' bundled adapters

Added:

- Added a runnable OLAP-on-Rails example (`examples/olap_on_rails.rb`): fact table,
  streaming ingestion, dictionary lookups, the aggregate-state pipeline, mutable
  dimensions via ReplacingMergeTree + `final`, partitions, and instrumentation —
  guarded by a live spec so it cannot drift
- Added `:binary`/`:blob` column types, mapped to `String` (ClickHouse strings are
  arbitrary byte sequences)
- Added `payload[:affected_rows]` to `sql.active_record` notifications, populated
  from the server summary's written rows on every query and on `insert_stream`
- Added case-insensitive `matches`/`does_not_match` rendering via ClickHouse's
  native `ILIKE` (LIKE is case-sensitive here, unlike MySQL); a custom ESCAPE
  character raises `NotImplementedError` because ClickHouse has no ESCAPE clause
- Added a no-op `FOR UPDATE` visitor (reads are isolated snapshots of parts; no row
  locks exist), so shared `Model.lock`/`with_lock` code runs instead of dying —
  optimistic locking via `lock_version` works end-to-end
- Added multi-replica support: `hosts:` lists interchangeable endpoints ("host" or
  "host:port"); connections round-robin their starting endpoint, fail over on
  connect-phase errors only (a request that never reached a server cannot double a
  write — mid-flight failures still raise), and skip endpoints that refused within
  `failover_cooldown:` seconds (default 30)
- Added `read_only: true` connection option: stamps `readonly=2` on every request so
  the server itself refuses writes; the refusal (code 164) raises
  `ActiveRecord::ReadOnlyError` — the same class Rails' `while_preventing_writes`
  uses — including for server-configured readonly users
- Added `ClickHouse::AccessDenied` (< `ActiveRecord::StatementInvalid`) for the
  server's grant refusals (code 497)
- Added `Errno::ENETUNREACH` to the failover connect-error list (connect-phase by
  nature, added on review — not reproducible in the test container)
- Added primary-key reporting for tables whose sorting key is a single integer or
  UUID column: Rails now auto-detects the model's primary key on id-keyed tables
  (`find`/`update`/`destroy` and client-generated ids work without
  `self.primary_key`); composite, expression, and non-id sorting keys still report
  none — ClickHouse PRIMARY KEY is an index prefix, not a uniqueness guarantee —
  and schema dumps keep the explicit `id: false` + `order:` shape
- Added Rails-style `create_table id: :bigint/:uuid` (and bare `id: :primary_key`,
  a plain Int64): the pk column doubles as the sorting key so no `order:` is
  needed, and ids are generated client-side — no autoincrement exists

Fixed:

- Fixed `lookup_cast_type` to resolve ClickHouse type names through the adapter's own
  parser: the abstract TYPE_MAP degraded `Nullable(...)`, `UUID`, `Bool`, and `Map`
  to bare `Type::Value` and even matched `Tuple(String, Int64)` as Integer; results
  are frozen so lookups stay Ractor-shareable
- Fixed `create_table` with a composite `primary_key:` array to render a quoted
  `PRIMARY KEY (a, b)` tuple; a PRIMARY KEY clause alone now satisfies the
  sorting-key requirement (the server infers ORDER BY from it)
- Fixed `disconnect!` to close the raw HTTP connection while still holding the
  adapter lock (the postgresql adapter's pattern) — closing after release let a
  concurrently queued query start its read on a dying socket
- Fixed SQL containing invalid UTF-8 bytes to reach the server instead of raising
  `ArgumentError` client-side (ClickHouse strings are byte sequences; the server
  accepts raw bytes in literals and backtick identifiers)
- Fixed datetime DDL bounds: precision past 9 (nanoseconds, ClickHouse's maximum) now
  raises `ArgumentError` at migration time instead of a server error, and an explicit
  `precision: nil` maps to the second-precision base `DateTime` (a bare `t.datetime`
  still gets Rails' default microseconds)
- Fixed schema dumps of datetime precision to follow Rails conventions: the default 6
  is omitted and a precision-less `DateTime` dumps as `precision: nil`
- Fixed attribute-less creates: Rails' `INSERT INTO t DEFAULT VALUES` is not ClickHouse
  syntax; the adapter now emits `FORMAT JSONEachRow {}` (one row, all table defaults)
- Updated datetime and date columns to expose `ActiveRecord::Type::DateTime`/`::Date`
  (not the ActiveModel types): they respect `ActiveRecord.default_timezone`, and
  Rails' time-zone-aware attribute machinery type-checks for them

Internal:

- Grew the Rails compatibility harness from ~2,200 to ~4,500 vendored upstream Active
  Record tests (scoping, autosave, migrations, nested attributes, serialized
  attributes, enums, dirty tracking, timestamps, batches, query cache, delegated
  types, instrumentation, and two dozen more suites), each skip documented with the
  dialect truth behind it
- Isolated the harness subprocess in a pid-suffixed ClickHouse database so concurrent
  runs cannot collide

# 0.1.0 (2026-07-15)

First release. Highlights:

- Full read-path type system: every ClickHouse type decodes to the right Ruby object
- RowBinary wire format by default, with transparent per-query JSON fallback
- Server-side bind parameters (`{pN:Type}` HTTP params) — no string interpolation
- MergeTree-aware migrations: engines, sorting keys, partitions, TTLs, codecs, projections, materialized views
- Full alter surface: `rename_column`, `change_column`, `change_column_null`, `change_column_default`, comments, and post-create `add_index`/`remove_index`
- `schema.rb` and `structure.sql` round-trip ClickHouse DDL, including projections and dictionaries
- OLAP relation surface: `final`, `prewhere`, `sample`, `settings`, `limit_by`, `array_join`, `group_by_period`, `fill`, `rollup`, `window`, `dict_get`
- Dictionaries: `create_dictionary` (columns inferred from source, credentials injected, cross-database via `database:`), `drop_dictionary`, `reload_dictionary`
- `ON CLUSTER` DDL via a `cluster:` connection setting
- Approximate aggregates: `uniq_count`, `quantile`, `top_k`, `arg_max`, `arg_min`, `estimated_count`, with `-If`/`-Merge` combinators
- `insert_stream`: chunked streaming bulk ingestion for lazy enumerables
- Client-side primary key generation (UUIDv7 / time-ordered Int64) via the prefetch seam
- Real instrumentation: `read_rows`, `read_bytes`, `written_rows`, `elapsed_ns` on every `sql.active_record` event
- TLS with verification on by default; `ssl_verify: false` for self-signed servers
- Rails compatibility harness: ~2,200 vendored upstream Active Record tests run green
