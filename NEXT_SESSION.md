# Iteration 47: 0.2.0 cut, or the core cutover PR

> Status at handoff: Iteration 46 landed primary-key auto-detection (decision
> #64, approved): `primary_keys(table)` reports a sorting key that is exactly
> one U/Int64+/UUID column — the same gate as the client-side id generator —
> so id-keyed tables are drop-in (find/update/destroy, generated ids, no
> `self.primary_key` boilerplate). Composite/expression/non-id keys still
> report `[]`; the schema dumper suppresses reporting to keep the id: false +
> order: dump shape. `create_table id: :bigint/:uuid` now works without
> order: (pk column doubles as sorting key; :primary_key native type is plain
> Int64). `Errno::ENETUNREACH` joined CONNECT_ERRORS (added blind, approved).
> Four harness skips erased. Suite 585 green, harness 5,558 runs / 447 skips,
> rubocop zero.

## Scope

Pick one (value order):

1. **Cut 0.2.0:** CHANGELOG is drafted (failover, read_only, AccessDenied, pk
   auto-detection, id: DSL), README covers all of it, benchmarks fresh
   (BASELINE.md 2026-07-18 — the pk-reporting change touches only SCHEMA
   queries, cached per connection, so no re-run needed unless requested).
   The release waits for Ikraam's explicit go.
2. **Core cutover PR:** the `adapter-port` worktree is committed and pinned to
   published 0.1.0; push the branch and open the PR when Ikraam wants it.
   Re-pin to 0.2.0 first if that ships.
3. **Corpus long tail (low value, deliberate deferrals):** pool machinery and
   the transactions family stay out unless a concrete consumer bug points at
   them.

## Watch out for (carried forward)

- **One driver only:** two concurrent full gates kill the Docker VM. Before
  any long gate: `pgrep -f "rspec|rails_compat"`. (The VM died again this
  iteration mid-spec — `docker desktop restart`, wait, `docker compose down
  && up -d --wait`, ~10s for the port proxy, rerun.)
- The tmpfs container fills after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243); compose down/up resets.
- Primary-key reporting (new): gated on `generatable_primary_key` — one
  cached lookup serves reporting and prefetch; the cache invalidates on
  create/drop/rename_table. The dumper wraps `super` in
  `with_suppressed_primary_key_reporting` — never dump with reporting on
  (Rails' dumper folds the pk into an implied id column, UInt64 → Int64).
- Harness `PRIMARY_KEYS` map now assigns explicit nils too (upstream declares
  those tables pk-less; detection would otherwise claim the slice's
  synthesized id sorting key — FinderTest's implicit-order test caught it).
- Failover: only CONNECT_ERRORS rotate endpoints — never widen the list to
  anything that can fire after the request reached a server.
- Read-only: `readonly=2`, never 1; grant checks fire before readonly checks
  (497 vs 164).
- The TRMNL corpus spec prefers a live ../core checkout; re-snapshot via the
  UPSTREAM file's cp command when core adds migrations.
- Manifest skips fire in `after_setup` (ledger #57); classes whose own
  setup/teardown breaks need a suite-level `"*"` overlay entry.
- The vendored corpus is pinned to 8.1.3; Rails-main text drift goes in
  `skips_edge.yml`. Edge bundle: `RAILS_SOURCE=edge BUNDLE_FROZEN=false
  bundle install`.
- Never assert `getSetting('async_insert')` is false — 26.x flipped the
  default; assert `system.settings.changed = 0` instead.
- LowCardinality ROLLUP totals: keyed `""` on 25.8, `nil` on 26.6.
- `change_column` builds MODIFY COLUMN from scratch: omitting `null: true` on
  a nullable column makes it non-nullable.
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).

## Open questions for Ikraam

- 0.2.0: ready to cut on request — say the word and it ships.
- `primary_keys` question is resolved (decision #64). Follow-up if a consumer
  asks: should an Int32/UInt32 single-column sorting key report as identity
  too? Today it doesn't (ids aren't generatable in 32 bits), so such models
  declare `self.primary_key` explicitly — conservative, revisit on demand.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 48.
