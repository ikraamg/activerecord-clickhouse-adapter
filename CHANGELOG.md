# 0.1.0 (unreleased)

First release. Highlights:

- Full read-path type system: every ClickHouse type decodes to the right Ruby object
- RowBinary wire format by default, with transparent per-query JSON fallback
- Server-side bind parameters (`{pN:Type}` HTTP params) — no string interpolation
- MergeTree-aware migrations: engines, sorting keys, partitions, TTLs, codecs, projections, materialized views
- `schema.rb` and `structure.sql` round-trip ClickHouse DDL
- OLAP relation surface: `final`, `prewhere`, `sample`, `settings`, `limit_by`, `array_join`, `group_by_period`, `fill`, `rollup`, `window`
- Approximate aggregates: `uniq_count`, `quantile`, `top_k`, `arg_max`, `arg_min`, `estimated_count`, with `-If`/`-Merge` combinators
- `insert_stream`: chunked streaming bulk ingestion for lazy enumerables
- Client-side primary key generation (UUIDv7 / time-ordered Int64) via the prefetch seam
- Real instrumentation: `read_rows`, `read_bytes`, `written_rows`, `elapsed_ns` on every `sql.active_record` event
- TLS with verification on by default; `ssl_verify: false` for self-signed servers
- Rails compatibility harness: ~1,850 vendored upstream Active Record tests run green
