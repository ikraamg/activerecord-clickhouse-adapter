# Iteration 23: release mechanics, or the next corpus

> Status at handoff: repo pushed to the private GitHub remote
> (`ikraamg/activerecord-clickhouse-adapter`) and the full CI matrix hardened in
> Iteration 22. First real Actions run exposed four environment truths the local
> setup couldn't: RuboCop scanning CI's `vendor/bundle` (Exclude replaced the
> defaults — now `inherit_mode: merge`), `Hash#inspect` drift on Ruby < 3.4 (the
> dumper now renders `settings:` itself), Rails main's new `QueryIntent`
> execution seam (dual-contract `perform_query`, ledger #50, plus
> `skips_edge.yml` for vendored-corpus text drift), and ClickHouse 26.6 drift
> (MODIFY COLUMN narrowing needs a DEFAULT clause, async_insert default flipped
> on, LowCardinality ROLLUP keys now null, Geometry/QBit added + Object removed
> — all probed live, §2). 487 rspec examples green on both 25.8 and 26.6,
> harness green on released 8.1 and edge, rubocop clean.

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
