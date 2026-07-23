# Iteration 49: PR babysitting, consumer feedback, or the long tail

> Status at handoff: Iteration 48 shipped everything. 0.2.0 is live on
> RubyGems (pushed 2026-07-23, MFA session was already open), main is
> fast-forwarded and pushed, tag v0.2.0 pushed. The core cutover PR is open:
> https://github.com/usetrmnl/core/pull/3902 — `clickhouse-adapter-port`
> rebased onto core master (clean), re-pinned to the published 0.2.0, and
> every ClickHouse-touching core spec ran green against the live adapter
> (109 telemetry-model + 50 request + rake examples; one intentional
> production-profile pending). The PR's remaining checkbox is a staging soak
> before production deploy.

## Scope

Pick by what's live (value order):

1. **Cutover PR feedback:** respond to review on usetrmnl/core#3902, fix CI
   if core's pipeline surfaces environment differences (its CI boots its own
   ClickHouse via docker-compose.clickhouse.yml — creds trmnl/trmnl:8123,
   unlike this repo's 18123 rails/rails).
2. **Consumer-driven fixes:** anything the staging soak or early 0.2.0
   adopters surface. Real bug reports outrank all remaining roadmap items.
3. **Corpus long tail (low value, deliberate deferrals):** pool machinery
   and the transactions family stay out unless a concrete consumer bug
   points at them. Parked question: Int32/UInt32 single-column sorting keys
   as detected identity (ids not generatable in 32 bits) — conservative no
   until asked.

## Watch out for (carried forward)

- **One driver only:** two concurrent full gates kill the Docker VM. Before
  any long gate: `pgrep -f "rspec|rails_compat"`. Recovery: `docker desktop
  restart`, wait, `docker compose down && up -d --wait`, ~10s port proxy.
- The tmpfs container fills after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243); compose down/up resets.
- Core spec runs from the adapter-port worktree: point the helper at this
  repo's container with `CLICKHOUSE_HOST=localhost CLICKHOUSE_PORT=18123
  CLICKHOUSE_USER=rails CLICKHOUSE_PASSWORD=rails CLICKHOUSE_DATABASE=<scratch>`
  and drop the scratch database afterwards; `CLICKHOUSE_PROOF_REQUIRED=true`
  turns unavailable-server skips into failures.
- `049a427` on this repo keeps its placeholder message ("Cursor: Apply local
  changes for cloud agent") — it was pushed before the split; rewording
  means a force push, default is leave it.
- Primary-key reporting is gated on `generatable_primary_key`; the dumper
  must keep wrapping `super` in `with_suppressed_primary_key_reporting`
  (reporting during dumps degrades UInt64 → Int64 on reload). Harness
  `PRIMARY_KEYS` assigns explicit nils for upstream's pk-less tables.
- Failover: only CONNECT_ERRORS rotate endpoints — never widen the list to
  anything that can fire after the request reached a server. Read-only:
  `readonly=2`, never 1; grant checks fire before readonly checks (497 vs
  164).
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
- `change_column` builds MODIFY COLUMN from scratch: omitting `null: true`
  on a nullable column makes it non-nullable.
- DateTime reads follow `default_timezone` (ledger #42); writes always
  encode UTC (ledger #23).

## Open questions for Ikraam

- The cutover PR's staging soak: run it when you're ready to point
  `CLICKHOUSE_HOST` at the staging sink; nothing else blocks merge from the
  adapter side.
- Post-release housekeeping: delete the merged `cursor/cloud-agent-*` branch
  on origin? (main already contains it.)

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 50.
