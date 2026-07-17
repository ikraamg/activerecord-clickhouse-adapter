# Iteration 35: core cutover PR, 0.2.0 release, or the next corpus

> Status at handoff: Iteration 34 landed four corpora. comment_test,
> aggregations_test, and explain_test pass in full with zero skips —
> comments, composed_of, and EXPLAIN were already exact. schema_dumper_test
> needed five slice tables (CamelCase, goofy_string_id, integer_limits,
> movies, string_key_objects) and 14 dump-shape convention skips; the
> SchemaDumperDefaultsTest class retires via a `"*"` entry (its own setup DDL
> uses t.time). No adapter changes. Harness: 3,815 runs / 320 skips. Gem
> suite 533 green, rubocop zero.

## Scope

Pick one (value order):

1. **Core cutover PR:** the `adapter-port` worktree is committed and pinned to
   the published 0.1.0; push the branch and open the PR when Ikraam wants it.
2. **Release:** the Unreleased CHANGELOG holds the decimal-DDL, binary/blob,
   empty-insert, and datetime-precision fixes. The datetime default-precision
   change (3 → 6) alters generated DDL, so this should probably be 0.2.0, not
   0.1.1 — decide with Ikraam.
3. **Next corpus:** remaining unvendored suites worth mining —
   `column_definition_test` (stub-adapter only, tiny), `bind_parameter_test`,
   `attribute_decorators_test`, or `inheritance_test` (STI — the slice already
   carries typed companies).

## Watch out for (carried forward)

- **Double-summary flake (new, Iteration 34):** one full-harness run printed a
  single `Run options` header but *two* `Finished in` summaries in one output,
  with mass fixture-wipe RecordNotFound failures across previously-green
  suites — i.e. two Minitest processes shared the run's stdout and database.
  The identical seed (32235) re-ran green with one summary. The only vendored
  `fork` site (BasicsTest#test_marshal_between_processes) is manifest-skipped
  and exit!-guarded, so the mechanism is unconfirmed. If a harness output
  shows two summaries, the run is invalid — re-run it; if it recurs, diagnose
  the fork instead of skipping tests.
- The full-gate storm is believed fixed by ledger #60 (harness owns
  `ar_clickhouse_compat`). If a wholesale embedded-harness failure ever
  reappears, it is a new bug, not the old flake — diagnose, don't re-run.
- Manifest skips fire in `after_setup` (ledger #57); a class whose *own
  setup/teardown* breaks needs a suite-level `"*"` overlay entry instead
  (ledger #59 — two exist: AttributeMethodsTest in skips_edge.yml,
  SchemaDumperDefaultsTest in skips.yml).
- The tmpfs container fills up after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243). `docker compose down && docker compose up -d
  --wait` is the factory reset. After the reset, give the port proxy ~10s —
  a run started the instant `--wait` returns has ECONNRESET'd every query once.
- `t.decimal precision: N` now emits `Decimal(N, 0)`; only a fully unbounded
  decimal keeps `Decimal(38, 10)`. Consumer schema diffs of `Decimal(N, 10)` →
  `Decimal(N, 0)` are this fix (the old shape was invalid for N < 10 anyway).
- `t.datetime` now defaults to precision 6. Any consumer schema diff noise of
  `DateTime64(3)` → `DateTime64(6)` is this, not a bug; explicit `precision: 3`
  restores the old shape. And since Iteration 33, `precision: nil` (explicit)
  means plain second-precision `DateTime` — schema dumps omit precision 6 and
  write `precision: nil` for the plain type, per upstream convention.
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
read/write path was touched, this file rewritten for Iteration 36.
