# Iteration 16: associations corpus or RowBinary performance pass (pick at session start)

> Status at handoff: 363 rspec examples green (plus the rails-compat harness: 1,128
> upstream minitest runs, 0 failures, 101 skips — 27 manifest, 74 capability
> self-skips), rubocop clean. Iteration 15 vendored `relations_test` (327 new runs)
> and fixed three adapter gaps it exposed: savepoint verbs are honest no-ops
> (ledger #33), multi-join qualified-star column names are stripped back to bare
> names when unambiguous (ledger #34), and the identifier matchers admit
> backtick-quoted names like MySQL's (ledger #35).

## Scope (two candidate tracks — confirm with Ikraam if both feel ripe)

**Track A — associations corpus.** `has_many_associations_test` /
`belongs_to_associations_test` are the biggest remaining untested read-path surface
(preloading, counter caches, dependent options). relations_test already pulled in
most of their models (reader, wheel, engine, bird, dats/*), so the marginal slice
cost is low. Expect skips on counter-cache tests (they mutate via UPDATE ... = x + 1
on sorting-key-adjacent columns) and touch: true chains.

**Track B — RowBinary + insert_stream performance iteration** (PLAN §6 Phase 8 note,
deferred twice): v2 read codec behind the existing codec interface, adopted only if
`benchmarks/round_trip.rb` proves it; `insert_stream` for bulk ingestion. This is the
last big performance lever before Phase 8 hardening.

## Watch out for (carried forward + new)

- The slice cannot carry a column named like its own table — it breaks every
  qualified star server-side (UNSUPPORTED_METHOD, §2). comments.comments stays out.
- A FROM alias equal to a real table name shadows that table in later JOINs
  (UNKNOWN_IDENTIFIER, §2) — alias-tracker style tests get manifest skips.
- create_or_find_by's conflict recovery can never fire (no unique constraints);
  its rollback tests need real transactions. Both reasons are already in skips.yml —
  reuse the wording for new suites.
- Rails' prefetch seam cannot populate one column of a composite primary key —
  cpk models whose slice table has a single-column sorting key hit
  `next_sequence_value(nil)`; skip, don't special-case.
- The mutation affected-row count is a pre-mutation `SELECT count()` (decision #24):
  raw-SQL mutations and LIMIT/ORDER statements return 0.
- `return_value_after_insert?` is false for every column (decision #25) — no
  RETURNING; DB-computed defaults need a reload.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420).
- No correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Remaining OLAP deferrals: window functions, dictionaries/dictGet, ON CLUSTER DDL,
  projections in schema.rb (structure.sql carries them today).

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the read/write
path was touched, this file rewritten for Iteration 17.
