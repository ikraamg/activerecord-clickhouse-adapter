# Iteration 32: core cutover PR, 0.1.1, or the next corpus

> Status at handoff: Iterations 30–31 landed five corpora. 30: serialized
> attribute + enum (203 runs; traffic_light model; harness skip-hook bug fixed,
> ledger #57 — manifest skips now fire in `after_setup`). 31: dirty +
> timestamp + attribute_methods (234 runs; five models, five slice tables,
> `fake` adapter registration, `InTimeZone`/`DdlHelper`/
> `with_temporary_connection_pool` helper ports). No adapter gaps in either.
> New seams: `no_last_insert_id` (raw insert can't report a row id) and
> `key_column_update` (partial_writes off updates the sorting key, code 420 —
> ledger #58). Harness: 3,642 runs / 295 skips. Gem suite 530 green, rubocop
> zero.

## Scope

Pick one (value order):

1. **Core cutover PR:** the `adapter-port` worktree is committed and pinned to
   the published 0.1.0; push the branch and open the PR when Ikraam wants it.
2. **Next corpus:** remaining unvendored suites worth mining —
   `calculations_test` siblings, `date_time_precision_test`, `time_precision_test`,
   `defaults_test`, or `reflection_test`.
3. **0.1.1 release:** the Unreleased CHANGELOG section already holds the
   decimal-DDL, binary/blob, and empty-insert fixes; cut it when Ikraam wants
   consumers to pick those up.

## Watch out for (carried forward)

- Full-gate flake, three sightings now (seeds 63425, 11977, 36176): a wholesale
  failure storm inside the embedded harness that vanishes on the identical
  re-run (36176 replayed green). Twice the harness's `jobs` table went missing
  mid-run with an ECONNRESET burst alongside. Standalone harness runs have
  never reproduced it. The parent suite and harness subprocess share
  `ar_clickhouse_test`, and the TRMNL corpus spec drops/recreates five table
  names the slice also owns (events/logs/jobs/requests/deploys) — sequential
  in-process, so the mechanism is still unproven. Policy: re-run the same seed
  before debugging; if it ever reproduces deterministically, give the harness
  subprocess its own database (cheap, kills the shared-namespace hazard).
- Manifest skips now fire in `after_setup` (ledger #57). If a vendored class's
  *setup itself* breaks on this adapter, an `after_setup` skip is too late —
  that case needs a class-level exclusion instead; none exist yet.
- The tmpfs container fills up after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243). `docker compose down && docker compose up -d
  --wait` is the factory reset. After the reset, give the port proxy ~10s —
  a run started the instant `--wait` returns has ECONNRESET'd every query once.
- `t.decimal precision: N` now emits `Decimal(N, 0)`; only a fully unbounded
  decimal keeps `Decimal(38, 10)`. Consumer schema diffs of `Decimal(N, 10)` →
  `Decimal(N, 0)` are this fix (the old shape was invalid for N < 10 anyway).
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
read/write path was touched, this file rewritten for Iteration 33.
