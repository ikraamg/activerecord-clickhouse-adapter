# Iteration 39: 0.2.0 readiness sweep, core cutover PR, or the next corpus

> Status at handoff: Iteration 38 landed batches (116 runs — find_each and
> in_batches fully work; four dialect skips) plus multiparameter, normalized
> attribute, secure_password, signed_id, and cache_key. normalized_attribute,
> secure_password, and signed_id pass untouched. New seams documented:
> mutation WHERE clauses render unqualified columns, writes-encode-UTC makes
> Time.local round-trips come back UTC, and RowBinary wire-casting means
> before_type_cast is never the raw database string (cache_version fast
> path). SecurePasswordTest's constant-time assertion is skipped as
> load-sensitive (0.5s wall-clock tolerance under a busy harness).
> Iterations 36–37 before it: store/secure_token/counter_cache + query_cache
> + twelve type/relation suites, the runnable examples/olap_on_rails.rb tour,
> and the pid-suffixed harness database that ended the double-summary flake.
> Harness: 4,434 runs / 358 skips. Gem suite 534 green, rubocop zero.

## Scope

Pick one (value order):

1. **0.2.0 readiness sweep:** Ikraam's bar for 0.2.0 is "pretty much drop-in
   for OLAP, with an example for OLAP-on-Rails". The example now exists. Sweep
   the remaining drop-in gaps: walk README claims against reality, re-run
   benchmarks, decide the version bump (datetime default-precision change is
   breaking-ish), and draft the CHANGELOG. Release only when Ikraam says so.
2. **Core cutover PR:** the `adapter-port` worktree is committed and pinned to
   the published 0.1.0; push the branch and open the PR when Ikraam wants it.
3. **Next corpus:** remaining unvendored suites worth mining —
   `delegated_type_test`, `readonly_test`, `touch_later_test`,
   `attributes_test`, `annotate_test`, `filter_attributes_test`, or the
   result/instrumentation pair (`result_test`, `instrumentation_test`).

## Watch out for (carried forward)

- **One driver only (violated in Iteration 36):** two agent sessions ran full
  gates concurrently; the pid stamps + system.query_log proved it. Before any
  long gate, `ls` the terminals folder / check for running rspec-ruby
  processes. The pid-suffixed harness database contains the blast radius, but
  the authored suite still owns `ar_clickhouse_test` exclusively — concurrent
  full gates will still collide there (spine tables, TRMNL corpus).
- The harness database is now `ar_clickhouse_compat_<pid>`, created in
  cases/helper.rb and dropped at_exit. `CLICKHOUSE_COMPAT_DATABASE` still
  overrides it (CI uses the default). Killed runs leave a debris database
  until the next `docker compose down`.
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
  corpus when 8.2 ships and delete the file. (Latest entry: LogSubscriber#sql
  takes an Event object on main — three bind_parameter logging tests.)
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
read/write path was touched, this file rewritten for Iteration 40.
