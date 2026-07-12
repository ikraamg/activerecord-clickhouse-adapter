# Iteration 8: compat corpus expansion + schema dumping

> Status at handoff: 181 rspec examples (incl. 41 upstream minitest runs) green, rubocop
> clean. Review-summit decisions are resolved and in the ledger (PLAN §5 #13–15).
> Iteration 7 delivered the Phase 7 performance core: notification stats, gzip
> compression, benchmarks/BASELINE.md, DateTime fast path, and pk-declared record
> mutations. The compat-corpus/schema-dumper items below were deferred from the original
> Iteration 7 brief when the review redirected to performance — they are now the scope.

## Scope

1. **Vendor `calculations_test`** (+ its schema slice) using the agreed rules:
   synthesized `order: "id"` lives in the harness schema only (decision #14),
   truncate-between-tests in the shim (decision #15). Grow `skips.yml` honestly —
   one-line reason per skip, manifest may only shrink afterwards.
2. **Schema dumper**: `schema.rb` round-trip preserving `engine/order/partition/ttl/
   settings` (custom `SchemaDumper` subclass via the adapter's `create_schema_dumper`
   seam), and `structure.sql` via `SHOW CREATE TABLE`. Acceptance: dump the TRMNL corpus
   schema, load it into a scratch database, re-introspect equal.
3. **`db:*` rake tasks** via `DatabaseTasks.register_task` (create/drop/purge at
   minimum).
4. **Grow the e2e spine**: schema dump → load → re-query leg.

## Watch out for

- The dumper must not emit `id: false` noise on every table (make it the dumper default)
  and must keep proc defaults (`-> { "now64(3)" }`) executable.
- `structure.sql` load path goes through `execute` batches — ClickHouse has no multi-
  statement support over HTTP; split on statement boundaries.
- Benchmarks: if the read/write path changes, re-run `bundle exec ruby
  benchmarks/round_trip.rb` and update `benchmarks/BASELINE.md` (history section).

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten + Alchemist
commits per coherent unit. Never push.
