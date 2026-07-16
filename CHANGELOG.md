# Unreleased

- Fixed decimal DDL bounds: `precision:` without `scale:` now means scale 0 (the old
  `Decimal(N, 10)` shape was invalid for N < 10), and `scale:` without `precision:`
  raises the same `ArgumentError` as Rails' bundled adapters
- Added `:binary`/`:blob` column types, mapped to `String` (ClickHouse strings are
  arbitrary byte sequences)
- Fixed attribute-less creates: Rails' `INSERT INTO t DEFAULT VALUES` is not ClickHouse
  syntax; the adapter now emits `FORMAT JSONEachRow {}` (one row, all table defaults)

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
