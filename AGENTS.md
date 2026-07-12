# Working agreement — activerecord-clickhouse-adapter

Read `PLAN.md` first (architecture, design ledger, phased roadmap), then `NEXT_SESSION.md`
(the current iteration's brief). This file is the standing contract for every session.

## Environment

```sh
docker compose up -d --wait     # ClickHouse 25.8 LTS, localhost:18123 (HTTP) / 19000 (native)
bundle install
bundle exec rspec               # real server only — the suite fails fast if it's down
bundle exec rubocop
```

- Test creds/db: `rails` / `rails` / `ar_clickhouse_test` (see `spec/spec_helper.rb`; `CLICKHOUSE_*` env overrides).
- Storage is tmpfs: `docker compose down && docker compose up -d --wait` is a factory reset.
- `RAILS_SOURCE=edge bundle exec rspec` runs against the local `../rails-main` worktree
  (Rails main / 8.2.0.alpha). Default target is released Active Record 8.1.
- Ruby 4.0.4 via mise. Add no runtime dependencies beyond stdlib + activerecord without
  discussing it in the session report first.

## Reference corpora (read-only — never modify these)

- `../rails-main` — Rails main source; the adapter contract of record.
- `../clickhouse` — sparse ClickHouse clone: `docs/`, `tests/queries/0_stateless/` (port
  oracle), `src/DataTypes`, `src/Formats`, `src/Core` (incl. `ErrorCodes` list).
- `../adapter-reference/` — prior art: `clickhouse-activerecord` (the incumbent, audited:
  see PLAN.md §3), `click_house`, `ch` + `ecto_ch` (best-designed reference), `clickhouse-js`.
- `../core` — TRMNL Rails app; real consumer (its `db/migrate_clickhouse/` is the Phase 3
  acceptance corpus). Do not edit it from these sessions.

## Non-negotiables

1. **Real-server TDD.** Write the failing spec first, watch it fail, then implement. No
   mocked wire responses, ever. If a behavior can't be proven against the live server, it
   doesn't ship.
2. **Spec style** (alchemist-rspec): named subject + `described_class`, one expectation per
   example, `let` over `let!`, `context` only when setup changes. Specs are the documentation.
3. **No monkeypatches** of ActiveRecord/Arel internals. Use official seams (see PLAN.md §5).
   If one is truly unavoidable, it lives quarantined in `lib/.../compat/`, version-guarded,
   with its own spec and a justification comment — and gets flagged in the session report.
4. **Accuracy over coverage theater.** Edge cases (min/max, nil, empty, unicode, timezone,
   precision) are the point. When ClickHouse behavior surprises you, capture it as a spec
   and a line in PLAN.md's grounding-facts table.
5. **KISS/YAGNI.** No speculative abstraction. Every LOC is a liability.
6. **Naming:** self-documenting in isolation, no ambiguous abbreviations, no invented jargon.
7. **Comments:** single-line gotchas only; rationale lives in specs and PLAN.md.
8. **Lint-clean before done:** `bundle exec rubocop` with zero offenses; full suite green.

## Session workflow

1. Read `PLAN.md` + `NEXT_SESSION.md`, boot the server, run the suite (must start green).
2. Do the iteration's work TDD-style.
3. Finish: full suite green, rubocop clean, `PLAN.md` updated (progress + any new grounding
   facts/decisions), `NEXT_SESSION.md` rewritten as the draft brief for the next iteration.
4. **Never commit or push unless Ikraam explicitly says so.** End with a report: what
   shipped, spec counts, surprises discovered live, open questions for review, and a
   proposed Alchemist-style commit split (past tense; Added/Updated/Fixed/Removed/Refactored;
   subject = WHAT, body = WHY) for Ikraam to approve.
