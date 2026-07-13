# Iteration 19: has_one/habtm corpora, or window functions

> Status at handoff: 429 rspec examples green plus the rails-compat harness at
> **1,805 upstream runs, 0 failures, 142 skips** (all manifest-documented or
> capability self-skips), rubocop clean. Iteration 18 shipped release readiness
> (CI matrix, ankane README, CHANGELOG, gemspec metadata, `gem build` verified —
> the 0.1.0 tag itself is Ikraam's call) and the `basics_test` corpus (180 runs,
> 9 manifest skips), which forced one adapter fix: DateTime reads now follow
> `ActiveRecord.default_timezone` for representation (ledger #42).

## Scope

Pick one (value order):

1. **`has_one` + `habtm` association suites.** The marginal-cost argument from
   Iteration 16 still holds: most models/fixtures are already vendored, and the
   skip families are established (query-count tallies, no-rollback, cpk-prefetch,
   anonymous-model pk). Expect a small slice delta.
2. **Window-function relation sugar.** The last big OLAP deferral: `OVER
   (PARTITION BY ... ORDER BY ...)` through a relation method in the
   `Querying` concern style (RelationMethods + dialect compilation), plus
   ClickHouse's non-standard window frames if cheap.
3. **0.1.0 release mechanics** if Ikraam green-lights: tag, push, `gem push`
   (needs credentials — stop and ask).

## Watch out for (carried forward + new)

- CI is untested against real GitHub Actions — the first push will tell. The edge
  job resolves Rails from the rails/rails monorepo (Gemfile git block) because CI
  has no ../rails-main worktree; BUNDLE_FROZEN=false is set for re-resolution.
- The harness now registers arunit/arunit2 named configurations (both point at the
  one test server) and runs with `raise_on_assign_to_attr_readonly = true` and
  `belongs_to_required_validates_foreign_key = false`, matching upstream's
  global_config. New suites may rely on more of that file — port flags as needed.
- Harness pk assignment now also covers abstract classes that pin a table
  (LoosePerson); models created inside test bodies still can't get one
  (anonymous_model_primary_key skip family).
- DateTime reads: representation follows `default_timezone` (ledger #42); writes
  still always encode UTC (ledger #23). Don't "fix" one by breaking the other.
- The read wire is RowBinary. Any new server type shows up as
  `RowBinary::Undecodable` → silent JSON fallback per query.
- The slice cannot carry a column named like its own table (UNSUPPORTED_METHOD,
  §2); `comments.comments` stays out. `weirds` proves `$`/unicode/reserved-word
  column names are fine.
- A FROM alias equal to a real table name shadows that table in later JOINs
  (UNKNOWN_IDENTIFIER, §2) — alias-tracker tests get manifest skips.
- Rails' prefetch seam cannot populate one column of a composite primary key —
  cpk models whose slice table has a single-column sorting key hit
  `next_sequence_value(nil)`; skip, don't special-case.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420); no
  correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Remaining OLAP deferrals: window functions, dictionaries/dictGet, ON CLUSTER
  DDL, projections in schema.rb (structure.sql carries them today).
- Core-port follow-ups: the `~/Documents/GitHub/core.worktrees/adapter-port`
  worktree holds the uncommitted core-side edits — Ikraam decides if/when that
  becomes a core PR.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 20.
