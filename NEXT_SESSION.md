# Iteration 24: core cutover support, release mechanics, or the next corpus

> Status at handoff: the migration corpus landed (Iteration 23). 15 of Rails'
> `migration/` sub-suites run byte-exact — 297 runs, 0 failures, 24 manifest
> skips. The alter surface is now Rails-contract: `add_index` accepts the full
> abstract option list (only `using:`/`granularity:` shape the DDL, ledger
> #52), `remove_index` delegates to `index_name_for_remove` (matches by
> columns, refuses name-shaped strings), `rename_index`/`rename_table`/
> `rename_column` rename auto-named indexes, `remove_column` drops dependent
> skip indexes, and `change_column` has replace-the-definition default
> semantics. Two behavior changes to know: `supports_datetime_with_precision?`
> is now true, so bare `t.datetime` produces `DateTime64(6)` not `(3)` (ledger
> #53), and inserting explicit NULL into a non-Nullable column now raises
> `NotNullViolation` (`input_format_null_as_default = 0`). 516 rspec examples
> green, rubocop clean.

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, `gem push` (needs
   credentials — stop and ask). CI is green across the matrix.
2. **Core cutover support:** the `~/Documents/GitHub/core.worktrees/adapter-port`
   worktree holds the uncommitted core-side edits; rerunning its migration
   corpus after Iteration 23's alter-surface hardening would derisk the cutover.
3. **Next corpus:** `autosave_association_test`, the `scoping` suites, or
   `migration_test.rb` itself (the big top-level file — the sub-suites are done).

## Watch out for (carried forward + new)

- `t.datetime` now defaults to precision 6. Any consumer schema diff noise of
  `DateTime64(3)` → `DateTime64(6)` is this, not a bug; explicit `precision: 3`
  restores the old shape.
- `primary_keys` still returns `[]` by design (§5) — the migration corpus skip
  for `test_removing_and_renaming_column_preserves_custom_primary_key` is the
  visible cost. Open question for Ikraam below.
- The vendored corpus is pinned to 8.1.3; against Rails main, drift in the test
  *text* (not adapter behavior) goes in `skips_edge.yml`, which merges into the
  manifest only when `ActiveRecord.gem_version >= 8.2.0.alpha`. Re-pin the
  corpus when 8.2 ships and delete the file.
- Rails main runs need the edge bundle: `RAILS_SOURCE=edge BUNDLE_FROZEN=false
  bundle install` re-resolves against `../rails-main` (all three path gems);
  plain `bundle install` restores the release lock afterwards.
- `change_column_null(…, false)` refuses stored NULLs without a backfill
  default; with a default it backfills via `mutations_sync = 1` first, then
  narrows with a placeholder `DEFAULT defaultValueOfTypeName(…)` it removes
  right after (§2).
- Never assert `getSetting('async_insert')` is false — 26.x flipped the server
  default. Assert `system.settings.changed = 0` for "the adapter didn't touch
  it".
- LowCardinality ROLLUP totals: keyed `""` on 25.8, `nil` on 26.6 — callers
  (and specs) must check both until 25.8 support ends.
- The Docker VM has died mid-run twice now (container OOM once, daemon gone
  once). If a run dies with "Connection refused"/ECONNRESET, check `docker ps`
  before debugging the adapter.
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
  error; raw `UPDATE t SET …` doesn't exist at all on 25.8 (mutations only) —
  the migration corpus skip documents it.
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).
- Rails' prefetch seam cannot populate one column of a composite primary key —
  skip, don't special-case.

## Open questions for Ikraam

- Should `primary_keys(table)` report a single-column sorting key as the AR
  primary key? Today it returns `[]` (ledger: PRIMARY KEY is an index prefix,
  not identity) and models declare `self.primary_key` explicitly. Inferring it
  would make `connection.primary_key` and model pk detection "just work" for
  id-keyed tables, but a table ordered by `created_at` would then claim a
  timestamp as its pk — dangerous for update/delete targeting. Status quo is
  the conservative call.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 25.
