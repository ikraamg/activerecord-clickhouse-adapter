# Iteration 48: publish 0.2.0, then the core cutover PR

> Status at handoff: Iteration 47 cut 0.2.0 locally — version bumped in
> gem_version.rb + gemspec (a spec enforces parity), CHANGELOG heading dated
> 2026-07-23, full combined gate green at the new version (586 examples incl.
> the 5,558-run harness, 0 failures, rubocop zero), and the .gem builds with
> the right contents (lib + CHANGELOG/LICENSE/README, nothing else). All of
> Iterations 45–46 is committed in seven Alchemist-style commits plus the
> release bump. Nothing is pushed or published — both need Ikraam's hands or
> explicit go.

## Scope (in order)

1. **Publish 0.2.0 (needs Ikraam):** `git push`, tag `v0.2.0`, `gem push
   activerecord-clickhouse-adapter-0.2.0.gem` (rubygems MFA is required by
   the gemspec metadata, so this is interactive). The built gem sits in the
   repo root, gitignored.
2. **Core cutover PR:** re-pin the `adapter-port` worktree from 0.1.0 to the
   published 0.2.0, push the branch, open the PR against core. Its
   `db/migrate_clickhouse/` corpus is already proven verbatim (27 migrations,
   snapshot @ b66bbb90b).
3. **Corpus long tail (low value, deliberate deferrals):** pool machinery and
   the transactions family stay out unless a concrete consumer bug points at
   them.

## Watch out for (carried forward)

- **One driver only:** two concurrent full gates kill the Docker VM. Before
  any long gate: `pgrep -f "rspec|rails_compat"`. Recovery: `docker desktop
  restart`, wait, `docker compose down && up -d --wait`, ~10s port proxy.
- The tmpfs container fills after several consecutive full-harness runs
  (NOT_ENOUGH_SPACE, code 243); compose down/up resets.
- `049a427` ("Cursor: Apply local changes for cloud agent") is a placeholder
  message but already pushed to origin — rewording means a force push;
  Ikraam's call, default is leave it.
- Primary-key reporting is gated on `generatable_primary_key` (one cached
  lookup serves reporting + prefetch; invalidated by create/drop/rename).
  The dumper must keep wrapping `super` in
  `with_suppressed_primary_key_reporting` — reporting during dumps folds the
  pk into an implied id column and degrades UInt64 → Int64 on reload.
- Harness `PRIMARY_KEYS` map assigns explicit nils (upstream's pk-less
  tables; detection would otherwise claim the synthesized id sorting key).
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
- `change_column` builds MODIFY COLUMN from scratch: omitting `null: true` on
  a nullable column makes it non-nullable.
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).

## Open questions for Ikraam

- Publish 0.2.0: everything is staged locally; push + tag + gem push are
  yours (MFA). Say the word if you want the push/tag done from here instead.
- Reword the pushed placeholder commit `049a427`? Requires force push;
  default is leave it.
- Follow-up parked: should an Int32/UInt32 single-column sorting key report
  as identity (detection-only, ids not generatable in 32 bits)? Conservative
  no for now; revisit on consumer demand.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 49.
