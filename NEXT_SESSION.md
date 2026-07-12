# Iteration 9: primary-key generation decision + compat corpus growth

> Status at handoff: 212 rspec examples green (incl. the rails-compat harness: 273
> upstream minitest runs, 0 failures, 24 manifest skips), rubocop clean. Iteration 8
> delivered Phase 3.5 (schema dumper with byte-identical TRMNL-corpus round-trip,
> `db:*` tasks via `DatabaseTasks.register_task`) and the calculations_test corpus,
> which forced four real adapter fixes: String bind escaping, `join_use_nulls=1`
> default (decision #16), TRUNCATE-based fixture loading (#17), plain-`Time`
> DateTimeCaster (#18).

## Blocking design question (ask Ikraam before implementing)

**Client-side primary-key generation** — 16 of the 24 skips trace to `create!`
without an explicit id (no autoincrement, no RETURNING; id stays nil, column stores 0).
Options in PLAN §9: (a) adapter-level `prefetch_primary_key?` + `next_sequence_value`
(UUIDv7/snowflake) for opted-in models, (b) harness-only shim, (c) document
"bring your own id". Recommendation: (a) — it converts 16 skips into passes and gives
consumers a real `create!` story; ecto_ch chose (c), the incumbent silently writes 0.

## Scope (after the decision)

1. Implement the chosen pk-generation option; if (a), shrink the skip manifest
   accordingly (the ratchet: `skips.yml` may only shrink).
2. **Vendor the next corpus**: `insert_all_test` (schema slice already covers several
   of its tables) and/or `basics_test` — same rules: decision #14 (synthesized
   `order: "id"` in the slice only) and #15 (truncate between tests).
3. **Grow the e2e spine** with whatever the iteration unlocks (e.g. `create!` without
   explicit id, fixture-style bulk seeds).
4. If touching the read/write path, re-run `bundle exec ruby benchmarks/round_trip.rb`
   and append to `benchmarks/BASELINE.md` history.

## Watch out for

- `basics_test` is huge and touches serialization/locking/dirty tracking — vendor it
  only if the skip manifest stays honest and readable; `insert_all_test` first.
- The GROUP BY functional-dependency and self-join AMBIGUOUS_IDENTIFIER skips are
  server semantics, not adapter bugs — do not try to "fix" them in SQL generation.
- Fixture YAMLs with ERB (`<%= %>`) evaluate in the harness — keep the vendored files
  byte-exact; adaptations belong in the schema slice or shim.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten + Alchemist
commits per coherent unit. Never push.
