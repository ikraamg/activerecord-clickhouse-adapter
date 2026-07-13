# Iteration 20: remaining association corpora, or release mechanics

> Status at handoff: 441 rspec examples green plus the rails-compat harness at
> **2,003 upstream runs, 0 failures, 154 skips** (all manifest-documented or
> capability self-skips), rubocop clean. Iteration 19 shipped the `has_one` +
> `habtm` corpora (198 new runs, 12 skips, zero adapter gaps — every failure fell
> into an established skip family) and window-function relation sugar
> (`.window(:fn, *cols, as:, partition_by:, order_by:, frame:)`, ledger #43).

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, push, `gem push`
   (needs credentials — stop and ask). CI gets its first real run on push.
2. **`has_one :through` / `has_many :through` corpora.** The through-association
   suites are the last big association corpora. Same marginal-cost argument:
   most models/fixtures are vendored; expect join-model slice tables and the
   established skip families.
3. **Remaining OLAP deferrals:** dictionaries/`dictGet`, ON CLUSTER DDL,
   projections in `schema.rb` (structure.sql carries them today).

## Watch out for (carried forward + new)

- CI is untested against real GitHub Actions — the first push will tell. The edge
  job resolves Rails from the rails/rails monorepo (Gemfile git block); the
  committed lock now includes bcrypt (test-only, for `models/user`'s
  `has_secure_password`).
- `.window` validates the function/alias against an identifier regex and the
  frame against ROWS/RANGE/GROUPS — columns quote themselves via arel_table.
  If a suite needs expression arguments (e.g. `sum(x + 1) OVER`), that's a
  deliberate non-feature so far.
- The harness registers arunit/arunit2 named configurations (both point at the
  one test server) and runs with `raise_on_assign_to_attr_readonly = true` and
  `belongs_to_required_validates_foreign_key = false`, matching upstream's
  global_config. New suites may rely on more of that file — port flags as needed.
- HAVING resolves SELECT aliases first (§2): a projected `SUM(x) AS x` makes
  `HAVING SUM(x)` nested (ILLEGAL_AGGREGATION) — manifest skip, don't rewrite.
- Raw `delete from t` / `update t set ...` without WHERE are syntax errors on
  ClickHouse (§2) — `raw_delete_without_where` / `raw_update_without_where`
  skip anchors exist.
- DateTime reads: representation follows `default_timezone` (ledger #42); writes
  still always encode UTC (ledger #23). Don't "fix" one by breaking the other.
- The read wire is RowBinary. Any new server type shows up as
  `RowBinary::Undecodable` → silent JSON fallback per query.
- Rails' prefetch seam cannot populate one column of a composite primary key —
  cpk models whose slice table has a single-column sorting key hit
  `next_sequence_value(nil)`; skip, don't special-case.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420); no
  correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Core-port follow-ups: the `~/Documents/GitHub/core.worktrees/adapter-port`
  worktree holds the uncommitted core-side edits — Ikraam decides if/when that
  becomes a core PR.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 21.
