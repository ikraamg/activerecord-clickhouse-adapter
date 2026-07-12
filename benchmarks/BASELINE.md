# Performance baseline

Produced by `bundle exec ruby benchmarks/round_trip.rb`. Regenerate and update this file
whenever the read path (`HTTPConnection#parse`, `Types` casters, `cast_result`) or the
write path changes materially.

## Current baseline — 2026-07-12

Apple Silicon (arm64-darwin25), Ruby 4.0.4 +PRISM, Active Record 8.1.3,
ClickHouse 25.8.28.1 in Docker (localhost), HTTP compression on (default).

| Benchmark | Throughput | Per iteration |
| --- | --- | --- |
| `select_all` 10k rows x 5 cols (typed) | 13.2 i/s | 75.9 ms |
| `pluck` 100k Int64 | 8.8 i/s | 114.2 ms |
| aggregate 100k rows server-side (`sum`) | 138.6 i/s | 7.2 ms |
| `insert_all!` 1k rows | 36.4 i/s | 27.5 ms |

Allocations for one `select_all` of 10k rows x 5 cols: **26.6 MB / 380,688 objects**.

## History

- **2026-07-12 — DateTimeCaster fast path.** `zone.parse` dominated the profile
  (17.7 MB of the then-43.2 MB per 10k-row select). The server always emits
  `YYYY-MM-DD HH:MM:SS[.fraction]`, so matching that shape and calling `zone.local`
  directly is 3.3x faster per value and took the 10k-row select from 5.3 i/s / 43.2 MB
  to 13.2 i/s / 26.6 MB.
- **2026-07-12 — first baseline** after enabling HTTP compression
  (`enable_http_compression=1`, ~3.6x smaller response bodies on 100k-row selects).

## Remaining hot spots (profiled 2026-07-12)

1. `JSON.parse` per line in `HTTPConnection#parse` (~4 MB / 10k rows) — a RowBinary
   codec would eliminate it, but current numbers do not justify the complexity yet
   (PLAN.md decision: benchmark-gated).
2. Row re-mapping in `cast_result` (~3.6 MB) — inherent to eager casting; revisit only
   if a lazy-casting `ActiveRecord::Result` seam appears upstream.
