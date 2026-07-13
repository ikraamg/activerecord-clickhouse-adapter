# Performance baseline

Produced by `bundle exec ruby benchmarks/round_trip.rb`. Regenerate and update this file
whenever the read path (`HTTPConnection#parse`, `Types` casters, `cast_result`) or the
write path changes materially.

## Current baseline — 2026-07-13

Apple Silicon (arm64-darwin25), Ruby 4.0.4 +PRISM, Active Record 8.1.3,
ClickHouse 25.8.28.1 in Docker (localhost), HTTP compression on (default),
RowBinaryWithNamesAndTypes read wire (default).

| Benchmark | Throughput | Per iteration |
| --- | --- | --- |
| `select_all` 10k rows x 5 cols (typed) | 23.5 i/s | 42.5 ms |
| `pluck` 100k Int64 | 12.0 i/s | 83.4 ms |
| aggregate 100k rows server-side (`sum`) | 210.2 i/s | 4.8 ms |
| `insert_all!` 1k rows | 37.6 i/s | 26.6 ms |
| `insert_stream` 1k rows | 178.5 i/s | 5.6 ms |
| `insert_stream` 100k rows (lazy enumerator) | 3.0 i/s | 336.2 ms |

Allocations for one `select_all` of 10k rows x 5 cols: **10.6 MB / 150,851 objects**.

## History

- **2026-07-13 — RowBinary read codec + insert_stream.** The read wire switched to
  `RowBinaryWithNamesAndTypes` (JSON per-query fallback for undecodable types): the
  10k-row select went 13.2 → 23.5 i/s and 26.6 MB → 10.6 MB allocated; `pluck` 100k
  Int64 went 8.8 → 12.0 i/s. `insert_stream` (chunked `JSONCompactEachRow` POST)
  moves the same 1k-row batch 4.8x faster than `insert_all!` (5.6 ms vs 26.6 ms)
  because nothing is rendered into a SQL string, and streams 100k lazy rows in one
  336 ms request (~297k rows/s) without materializing the batch.
- **2026-07-12 — DateTimeCaster fast path.** `zone.parse` dominated the profile
  (17.7 MB of the then-43.2 MB per 10k-row select). The server always emits
  `YYYY-MM-DD HH:MM:SS[.fraction]`, so matching that shape and calling `zone.local`
  directly is 3.3x faster per value and took the 10k-row select from 5.3 i/s / 43.2 MB
  to 13.2 i/s / 26.6 MB.
- **2026-07-12 — first baseline** after enabling HTTP compression
  (`enable_http_compression=1`, ~3.6x smaller response bodies on 100k-row selects).

## Remaining hot spots (profiled 2026-07-13)

1. Row re-mapping in `cast_result` — RowBinary already yields final Ruby values, but
   the caster pass still walks every row (idempotently) so both wires share one cast
   layer. A "pre-cast" flag on `RawResult` could skip it; measure before adding.
2. `Benchmark.ips`-visible variance on `pluck` suggests the per-value lambda dispatch
   in `RowBinary#decode` is the next micro-target if plucks ever dominate a workload.
