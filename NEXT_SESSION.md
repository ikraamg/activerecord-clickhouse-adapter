# Iteration 7 (post-review): expand the compat corpus + schema dumping

> Status: REVIEW SUMMIT REACHED. The Phase 6 rails-compat harness landed
> (spec/rails_compat/: v8.1.3-pinned vendored suites, skip-manifest ratchet, RSpec
> wrapper). 168 rspec examples + 41 upstream minitest runs green, rubocop clean,
> tree committed. Waiting on Ikraam's review before continuing.

## Open design questions for the review (blockers for this iteration)

1. **Schema translation rule for upstream suites.** Rails' schema.rb creates hundreds
   of implicit-id tables. Options: (a) synthesize `order: "id"` + a client-generated
   id per insert for compat tables only; (b) skip id-dependent suites wholesale in the
   manifest; (c) a compat-only `id: :uuid` default. Recommendation: (a) for the
   narrow set of suites we vendor, since it exercises realistic pk-less semantics least.
2. **Fixture strategy.** Rails fixtures want transactional rollback (impossible) or
   truncation. Recommendation: truncate-between-tests helper in the shim, mirroring
   the incumbent gem's test-helper hooks (PLAN §3 "worth keeping").
3. **`update`/`save` on loaded records** (deferred from Iteration 4): with no pk,
   `record.update` cannot target a row. Options: raise with guidance (honest), or
   support it only for models that declare `self.primary_key = ...` explicitly.
   Recommendation: the latter — it matches ReplacingMergeTree usage patterns.

## Scope once unblocked

1. Apply review feedback.
2. Vendor `calculations_test` (+ its schema slice) with the agreed schema rule;
   grow skips.yml honestly.
3. Schema dumper (`schema.rb` with engine/order/partition options round-trip,
   `structure.sql` via SHOW CREATE) — Phase 3 deferred item, needed before TRMNL
   swap-over (Phase 9).
4. `db:*` rake tasks via `DatabaseTasks.register_task`.
5. Grow the e2e spine with schema dump → load → re-query.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten + Alchemist
commits per coherent unit. Never push.
