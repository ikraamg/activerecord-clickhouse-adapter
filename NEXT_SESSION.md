# Iteration 23: release mechanics, or the next corpus

> Status at handoff: CI matrix hardened (Iteration 22) and the harness's
> version story finished (Iteration 22b): a weekly drift workflow
> (`.github/workflows/drift.yml`) runs Rails main + ClickHouse `head` decoupled
> from merge-gating CI; skip overlays are a data-driven registry
> (`SKIP_OVERLAYS` in `support/cases/helper.rb`); TRMNL core's migrations are
> snapshotted byte-exact in `spec/vendor/trmnl_corpus/` so CI runs the
> acceptance corpus without the private checkout (a local `../core` still takes
> precedence); and the ClickHouse floor is documented as 25.8 — 25.3 was probed
> live and fails on RowBinary JSON columns, window frames, and EXPLAIN shapes.
> Policy lives in PLAN.md §7 "Version matrix policy" (corpus re-pin cadence,
> overlay lifecycle, floor rationale). 490 rspec examples green, rubocop clean.

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, `gem push` (needs
   credentials — stop and ask). CI is now green across the matrix.
2. **Next corpus:** `migration_test` is now worth attempting — the alter surface
   it exercises exists as of Iteration 21. Alternatively
   `autosave_association_test` or the `scoping` suites.
3. **Dialect deepening:** ON CLUSTER for the dialect verbs (projections,
   partitions, OPTIMIZE, dictionaries); dictionary layouts beyond FLAT/HASHED
   (complex_key_*, range_hashed) when a consumer shape shows up.

## Watch out for (carried forward + new)

- The vendored corpus is pinned to 8.1.3; against Rails main, drift in the test
  *text* (not adapter behavior) goes in `skips_edge.yml`, which merges into the
  manifest only when `ActiveRecord.gem_version >= 8.2.0.alpha`. Re-pin the
  corpus when 8.2 ships and delete the file.
- Rails main runs need the edge bundle: `RAILS_SOURCE=edge BUNDLE_FROZEN=false
  bundle install` re-resolves against `../rails-main` (all three path gems);
  plain `bundle install` restores the release lock afterwards.
- `change_column_null(…, false)` now refuses stored NULLs without a backfill
  default (explicit ActiveRecordError) because 26.6's DEFAULT-clause narrowing
  would rewrite them silently; with a default it backfills via `mutations_sync
  = 1` first, then narrows with a placeholder `DEFAULT
  defaultValueOfTypeName(…)` it removes right after (§2).
- Never assert `getSetting('async_insert')` is false — 26.x flipped the server
  default. Assert `system.settings.changed = 0` for "the adapter didn't touch
  it".
- LowCardinality ROLLUP totals: keyed `""` on 25.8, `nil` on 26.6 — callers
  (and specs) must check both until 25.8 support ends.
- The Docker VM killed the ClickHouse container mid-harness once (exit 137 =
  OOM/SIGKILL). If harness runs die with "Connection refused", check `docker
  ps` before debugging the adapter.
- `change_column` builds MODIFY COLUMN from scratch: type wrappers come from
  options, not the previous column — omitting `null: true` on a nullable column
  makes it non-nullable (same replace-the-definition semantics as Rails).
- structure_load rewrites USER/PASSWORD inside CREATE DICTIONARY statements
  with the loading connection's credentials — a dictionary authenticating as
  someone else is not expressible yet.
- The compose file runs an embedded Keeper (`spec/support/cluster/keeper.xml`);
  a stale container predating Iteration 20 fails the on_cluster spec with
  NO_ELEMENTS_IN_CONFIG.
- HAVING resolves SELECT aliases first (§2); raw DML without WHERE is a syntax
  error (`raw_update_without_where`/`raw_delete_without_where` anchors);
  `self_join_ambiguity` anchor for unaliased base tables in self-joins.
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).
- Rails' prefetch seam cannot populate one column of a composite primary key —
  skip, don't special-case.
- Core-port follow-ups: the `~/Documents/GitHub/core.worktrees/adapter-port`
  worktree holds the uncommitted core-side edits — Ikraam decides if/when that
  becomes a core PR.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 24.
