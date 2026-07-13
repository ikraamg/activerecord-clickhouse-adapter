# Iteration 18: basics_test corpus (the last big compat suite)

> Status at handoff: 420 rspec examples green (plus the rails-compat harness: 1,619
> upstream minitest runs, 0 failures, skips all manifest-documented), rubocop clean. Iteration 17 was the
> Phase 9 proving ground: TRMNL core runs on this adapter in the
> `~/Documents/GitHub/core.worktrees/adapter-port` worktree — all 10 sink migrations
> verbatim, every ClickHouse-touching core spec green under
> `CLICKHOUSE_PROOF_REQUIRED=true`, zero query rewrites needed. The port forced three
> adapter fixes (ledger #39–#41): `insert_all` duplicate-skip is now vacuously
> satisfied, trailing sqlcommenter comments are hoisted on INSERT, and the gemspec no
> longer touches the ActiveRecord namespace (path-gem consumers used to crash at boot).

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

**Core-port follow-ups (small, from Iteration 17):** the port worktree still holds
two uncommitted core-side edits (Gemfile swap, `connection_pool.migration_context`
in `lib/tasks/clickhouse.rake`) — Ikraam decides if/when that becomes a core PR.
The adapter's `ssl: true` path verifies certs (incumbent was VERIFY_NONE); prod
sinks on self-signed certs need a `verify_mode`/`ssl_verify: false` escape hatch
before this swap can deploy — worth a spec'd config option this iteration if time
allows.

## Watch out for (carried forward + new)

- `insert_all` no longer raises — duplicate rows insert cleanly (ledger #39). Any
  spec that asserted the old ArgumentError is already updated; don't reintroduce it.
- ClickHouse rejects trailing `/*...*/` after `INSERT ... VALUES` (code 27);
  `hoist_trailing_comments` moves them to the front of INSERTs only (ledger #40).
- Never `require_relative` the version file from the gemspec (ledger #41) — the
  namespace-isolation spec guards this.
- The read wire is RowBinary. Any new server type shows up as
  `RowBinary::Undecodable` → silent JSON fallback per query.
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
  that follows the ORDER/LIMIT subquery rewrite (ledger #36); raw-SQL
  mutations still return 0.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420); no
  correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Remaining OLAP deferrals: window functions, dictionaries/dictGet, ON CLUSTER
  DDL, projections in schema.rb (structure.sql carries them today).

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 19.
