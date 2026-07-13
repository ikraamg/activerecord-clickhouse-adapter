# Iteration 11: persistence_test corpus (update/destroy semantics at scale)

> Status at handoff: 238 rspec examples green (incl. the rails-compat harness: 636
> upstream minitest runs, 0 failures, 87 skips — 13 manifest, 74 capability self-skips),
> rubocop clean. Iteration 10 landed the per-connection sorting-key cache (decision #21,
> invalidated by create/drop/rename_table), `rename_table`, the nil-bind fix (decision
> #22: `Nullable(Nothing)`/`\N` — nil String binds were silently becoming `''`), and the
> finder_test corpus (+12 models, +9 fixture sets, +18 slice tables). Note: `basics_test`
> does not exist at v8.1.3 — finder_test was the honest fallback, per the old brief.

## Scope

1. **Vendor `persistence_test`** (v8.1.3, byte-exact, 1774 lines) — the natural next
   corpus now that create/update/destroy all work: it exercises update_columns, touch,
   becomes, destroy, and dup. Requires ~15 new model files (aircraft, dashboard, person,
   parrot, pirate graph...) with transitive requires; walk them one `require` at a time.
   Expect honest manifest skips for optimistic locking (no ClickHouse story) and
   anything needing read-your-write of a mutation Rails fires without `mutations_sync`.
2. **Schema slice growth rules stay decisions #14/#15**: synthesized `order: "id"`
   Int64 ids, all columns `null: true` unless the sorting key needs them, FK columns
   `limit: 8`. New from Iteration 10: never carry a column named like its own table
   (`comments.comments` breaks the qualified matcher, §2), and `PRIMARY_KEYS` in the
   slice supports explicit `nil` for tables whose models must stay pk-less.
3. **Grow the e2e spine** with whatever lands (update/reload round trip, destroy).
4. If touching the read/write path, re-run `bundle exec ruby benchmarks/round_trip.rb`
   and append to `benchmarks/BASELINE.md` history.

## Watch out for

- The sorting-key cache invalidates only via the migration-API DDL methods; raw
  `execute("CREATE TABLE ...")` in specs must not rely on prefetch picking the change up.
- Models that declare a pk whose column type can't be generated (String, composite)
  raise from `next_sequence_value` with guidance when created without an id. That's
  decision #19's intent — manifest-skip upstream tests that rely on it instead of
  weakening the raise.
- The GROUP BY functional-dependency and self-join AMBIGUOUS_IDENTIFIER skips are
  server semantics, not adapter bugs — do not try to "fix" them in SQL generation.
- `default_timezone = :local` cannot work: DateTime64 params reject timezone offsets
  and columns store naive UTC wall-clock (§2). Skip such tests with that reason.
- Fixture YAMLs with ERB (`<%= %>`) evaluate in the harness — keep the vendored files
  byte-exact; adaptations belong in the schema slice or shim.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten + Alchemist
commits per coherent unit. Never push.
