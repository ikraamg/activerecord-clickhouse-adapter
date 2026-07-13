# Iteration 17: basics_test corpus (the last big compat suite)

> Status at handoff: 415 rspec examples green (plus the rails-compat harness: 1,619
> upstream minitest runs, 0 failures, 138 skips — 64 manifest, 74 capability
> self-skips), rubocop clean. Iteration 16 landed both tracks: the associations
> corpus (`belongs_to` + `has_many`, ledger #36 mutation-count rewrite, subquery
> qualifier preservation) and the performance pair — RowBinary default read wire
> with per-query JSON fallback (ledger #37) and `insert_stream` chunked bulk
> ingestion (ledger #38). Baseline roughly doubled: 10k-row select 13.2 → 23.5 i/s
> at 10.6 MB; 1k-row ingest 5.6 ms via stream vs 26.6 ms via insert_all!.

## Scope

**`basics_test` corpus.** The one big upstream suite still unvendored (~1,500 runs
upstream); it exercises attribute semantics, column aliasing, serialization, and
pk edge cases end to end. Expect the largest skip triage yet — reuse the skips.yml
anchors (query-count tallies, no-unique-constraint, no-rollback, cpk-prefetch,
create_table-needs-order) before inventing new wording. Models/fixtures overlap
heavily with what relations/associations already vendored, so the marginal slice
cost should be moderate.

If `basics_test` lands early, candidates in value order: `has_one` +
`habtm` association suites (small marginal cost now), or window-function relation
sugar (the last big OLAP deferral).

## Watch out for (carried forward + new)

- The read wire is now RowBinary. Any new server type shows up as
  `RowBinary::Undecodable` → silent JSON fallback per query — if a harness test
  gets mysteriously slow, check whether its type fell back (log the format on
  the retry if this bites).
- `insert_stream` takes column names from the first row; rows with differing key
  sets silently insert defaults for the missing columns.
- The slice cannot carry a column named like its own table (UNSUPPORTED_METHOD, §2);
  `comments.comments` stays out.
- A FROM alias equal to a real table name shadows that table in later JOINs
  (UNKNOWN_IDENTIFIER, §2) — alias-tracker tests get manifest skips.
- Rails' prefetch seam cannot populate one column of a composite primary key —
  cpk models whose slice table has a single-column sorting key hit
  `next_sequence_value(nil)`; skip, don't special-case.
- Mutation affected-row counts are a pre-mutation `SELECT count()` (decision #24)
  that now follows the ORDER/LIMIT subquery rewrite (ledger #36); raw-SQL
  mutations still return 0.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420); no
  correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Remaining OLAP deferrals: window functions, dictionaries/dictGet, ON CLUSTER
  DDL, projections in schema.rb (structure.sql carries them today).

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 18.
