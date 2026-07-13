# Iteration 10: basics_test corpus (or the next honest slice of it)

> Status at handoff: 227 rspec examples green (incl. the rails-compat harness: 362
> upstream minitest runs, 0 failures, 83 skips — 9 manifest, 74 capability self-skips),
> rubocop clean. Iteration 9 landed client-side primary keys (decision #19: prefetch
> via `prefetch_primary_key?`/`next_sequence_value`; time-ordered 63-bit Int64 ids or
> UUIDv7 when the sorting key is one generatable column), which erased all 16
> no-autoincrement skips, plus the insert_all_test corpus, `high_precision_current_timestamp`
> = `now()` (decision #20), and the boolean-literal-default fix that kept
> `auto_populated?` honest.

## Scope

1. **Vendor `basics_test`** (v8.1.3, byte-exact) — the biggest remaining corpus. It
   touches serialization, dirty tracking, locking, and readonly; expect a wave of
   schema-slice tables and some honest manifest skips (optimistic locking has no
   ClickHouse story, for instance). If the manifest entries stop being one-line honest
   reasons, stop and vendor a smaller suite instead (`finder_test` or
   `persistence_test` are the next candidates).
2. **Schema slice growth rules stay decisions #14/#15**: synthesized `order: "id"`
   Int64 ids, all columns `null: true` unless the sorting key needs them (Nullable
   sorting keys raise ILLEGAL_COLUMN — Iteration 9 fact), FK columns `limit: 8`
   (generated ids are 63-bit; Int32 FKs overflow — Iteration 9 lesson).
3. **Grow the e2e spine** with whatever lands (dirty tracking round trip, readonly).
4. If touching the read/write path, re-run `bundle exec ruby benchmarks/round_trip.rb`
   and append to `benchmarks/BASELINE.md` history.

## Watch out for

- `prefetch_primary_key?` costs one SCHEMA query per `create!` (Rails does not cache
  it per model). If basics_test's create-heavy tests crawl, consider a per-connection
  sorting-key cache invalidated on DDL — flag it as a design note, don't gold-plate.
- Models that declare a pk whose column type can't be generated (String, composite)
  now raise from `next_sequence_value` with guidance when created without an id.
  That's decision #19's intent — manifest-skip upstream tests that rely on it instead
  of weakening the raise.
- The GROUP BY functional-dependency and self-join AMBIGUOUS_IDENTIFIER skips are
  server semantics, not adapter bugs — do not try to "fix" them in SQL generation.
- Fixture YAMLs with ERB (`<%= %>`) evaluate in the harness — keep the vendored files
  byte-exact; adaptations belong in the schema slice or shim.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten + Alchemist
commits per coherent unit. Never push.
