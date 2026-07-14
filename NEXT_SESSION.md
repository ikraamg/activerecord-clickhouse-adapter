# Iteration 25: release mechanics or the next corpus

> Status at handoff: Iteration 24 repaired the matrix and derisked the cutover.
> The two CI failures from the Iteration 23 push are fixed: Rails main renamed
> `Column#fetch_cast_type` → `cast_type` (pinned-text entries in
> `skips_edge.yml`), and ClickHouse 26.6's in-statement-DEFAULT rule reached
> `change_column` through the migration corpus (same placeholder round-trip as
> `change_column_null`, stored-NULLs guard included, proven live on 26.6.1).
> Core cutover status: in `~/Documents/GitHub/core.worktrees/adapter-port` all
> 14 sink migrations run verbatim on a fresh database and every
> ClickHouse-touching spec is green (12 proof + 100 request + 184 model/task
> examples). The worktree gained one core-side fix: the four append-only sink
> models declare `self.primary_key = nil` so an early pk resolution against the
> unwired Postgres pool can't cache a guessed `"id"` (latent with the incumbent
> gem too — worth carrying into the real cutover PR). 524 rspec examples green
> on 25.8, authored tier green on 26.6, rubocop clean.

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, `gem push` (needs
   credentials — stop and ask). CI is green across the matrix.
2. **Core cutover PR:** the worktree edits (Gemfile swap, `ssl_verify: false`,
   `migration_context` rename, sink `primary_key = nil`) are ready to become
   the real cutover PR on core once Ikraam wants it opened.
3. **Next corpus:** `autosave_association_test`, the `scoping` suites, or
   `migration_test.rb` itself (the big top-level file — the sub-suites are done).

## Watch out for (carried forward)

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
- Narrowing to non-Nullable (via `change_column_null` *or* `change_column`)
  refuses stored NULLs and rides a placeholder
  `DEFAULT defaultValueOfTypeName(…)` it removes right after (§2) — 26.6
  requires the in-statement DEFAULT, 25.8 tolerates it.
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
read/write path was touched, this file rewritten for Iteration 26.
