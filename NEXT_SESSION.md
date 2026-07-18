# Iteration 42: the next corpus batch, 0.2.0 cut, or core cutover PR

> Status at handoff: Iteration 41 landed six adapter-surface corpora
> (adapter, database_statements, primary_keys, statement_invalid,
> table_metadata, types) and three adapter fixes that fell out:
> `lookup_cast_type` now routes through the gem's type parser (frozen results,
> Ractor-shareable) instead of the abstract TYPE_MAP that degraded ClickHouse
> shapes; composite `primary_key:` arrays render as a PRIMARY KEY tuple and a
> PRIMARY KEY clause alone satisfies the sorting-key requirement (server
> infers ORDER BY, probed live); and `disconnect!` closes the raw connection
> inside `@lock` (postgresql-adapter pattern — a queued query was starting
> its HTTP read on a dying socket, seen live as IOError). Skips: FK suite
> retires class-level (no FK constraints), thread-safety probes (no
> lock_thread pinning in a transactionless harness), AdapterConnectionTest
> self-skips via upstream's own remote_disconnect/raw_transaction_open?
> seam. Harness: 4,918 runs / 429 skips. Gem suite 546 green, rubocop zero.

## Scope

Pick one (value order):

1. **Next corpus batch:** remaining unvendored suites worth mining —
   `attribute_decorators_test`, `store_test`, `secure_token_test`,
   `counter_cache_test`, `quoting_test`, `sanitize_test`, `batches_test`.
   The ratchet keeps finding real bugs (three adapter fixes in Iteration 41),
   so keep pulling.
2. **Cut 0.2.0:** CHANGELOG is drafted, benchmarks re-run (BASELINE.md
   2026-07-18), README audited, the OLAP example ships and is guard-spec'd.
   Ikraam's bar — "pretty much drop-in for OLAP + an example" — reads as met;
   the release itself waits for his explicit go (version bump decision:
   datetime default-precision change is breaking-ish, suggesting 0.2.0 over
   0.1.1).
3. **Core cutover PR:** the `adapter-port` worktree is committed and pinned to
   published 0.1.0; push the branch and open the PR when Ikraam wants it.
   Re-pin to 0.2.0 first if that ships.

## Watch out for (carried forward)

- **One driver only (violated again in Iteration 41):** a second session's
  full harness ran concurrently with this one's — the container hit
  225,000% CPU, then the Docker VM died (fourth time). The pid-suffixed
  harness database contains the *data* blast radius, but the box does not
  survive two concurrent full gates. Before any long gate:
  `pgrep -f "rspec|rails_compat"`.
- Docker VM recovery: `docker desktop restart` (or quit + relaunch), wait for
  the daemon, then `docker compose down && up -d --wait`, then give the port
  proxy ~10s. Right after recovery, expect a few ConnectionNotEstablished
  connect-timeout flakes in the first harness run — rerun the affected suites
  before suspecting the adapter.
- The harness database is `ar_clickhouse_compat_<pid>`, created in
  cases/helper.rb and dropped at_exit. `CLICKHOUSE_COMPAT_DATABASE` still
  overrides it (CI uses the default). Killed runs leave a debris database
  until the next `docker compose down`.
- `active?` is honestly false on a virgin connection (connecting is lazy);
  call `verify!` first if a spec needs an established connection.
- Manifest skips fire in `after_setup` (ledger #57); a class whose *own
  setup/teardown* breaks needs a suite-level `"*"` overlay entry instead
  (three exist: AttributeMethodsTest in skips_edge.yml,
  SchemaDumperDefaultsTest and AdapterForeignKeyTest in skips.yml).
- The tmpfs container fills up after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243). `docker compose down && docker compose up -d
  --wait` is the factory reset.
- `clean_up_connection_handler` must never strip pools whose db_config
  adapter is "fake" — Contact/ContactSti are load-time fixtures shared by the
  serialization suites, and this harness is one process (Iteration 40).
- `PRIMARY_KEYS` in schema_slice.rb wins over the lazy `table_exists?` guess;
  scratch-table models (ReservedWordTest) are only reachable through manifest
  entries because their tables don't exist at boot.
- `t.decimal precision: N` now emits `Decimal(N, 0)`; only a fully unbounded
  decimal keeps `Decimal(38, 10)`.
- `t.datetime` defaults to precision 6; explicit `precision: nil` means plain
  second-precision `DateTime` — schema dumps omit precision 6 and write
  `precision: nil` for the plain type, per upstream convention.
- `primary_keys` still returns `[]` by design (§5) — open question for Ikraam
  below.
- The vendored corpus is pinned to 8.1.3; against Rails main, drift in the
  test *text* goes in `skips_edge.yml` (merged only when
  `ActiveRecord.gem_version >= 8.2.0.alpha`). Re-pin when 8.2 ships and
  delete the file.
- Rails main runs need the edge bundle: `RAILS_SOURCE=edge BUNDLE_FROZEN=false
  bundle install`; plain `bundle install` restores the release lock.
- Narrowing to non-Nullable refuses stored NULLs and rides a placeholder
  `DEFAULT defaultValueOfTypeName(…)` it removes right after (§2).
- Never assert `getSetting('async_insert')` is false — 26.x flipped the
  default. Assert `system.settings.changed = 0` instead.
- LowCardinality ROLLUP totals: keyed `""` on 25.8, `nil` on 26.6 — check both.
- `change_column` builds MODIFY COLUMN from scratch: omitting `null: true` on
  a nullable column makes it non-nullable.
- structure_load rewrites USER/PASSWORD inside CREATE DICTIONARY statements
  with the loading connection's credentials.
- The compose file runs an embedded Keeper; a stale container predating
  Iteration 20 fails the on_cluster spec with NO_ELEMENTS_IN_CONFIG.
- HAVING resolves SELECT aliases first (§2); raw DML without WHERE is a
  syntax error; raw `UPDATE t SET …` doesn't exist on 25.8 (mutations only).
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).
- Rails' prefetch seam cannot populate one column of a composite primary key —
  skip, don't special-case.

## Open questions for Ikraam

- Should `primary_keys(table)` report a single-column sorting key as the AR
  primary key? Today it returns `[]` (ledger: PRIMARY KEY is an index prefix,
  not identity) and models declare `self.primary_key` explicitly. Status quo
  is the conservative call.
- 0.2.0: ready to cut on request — CHANGELOG drafted, benchmarks fresh, OLAP
  example guard-spec'd. Confirm the version number (datetime precision default
  change argues for 0.2.0 over 0.1.1).

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 43.
