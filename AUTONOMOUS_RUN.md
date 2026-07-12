# Autonomous multi-iteration run

You are running an autonomous, multi-iteration session on the activerecord-clickhouse-adapter
project at `/Users/ikraam/Documents/GitHub/activerecord-clickhouse-adapter`. Work ONLY in this
repo. The sibling corpora (`../rails-main`, `../clickhouse`, `../adapter-reference/*`, `../core`)
are read-only references — never modify them. One driver rule: if `git status` shows churn you
didn't cause, another session is driving — stop and ask Ikraam.

## First actions, in order

1. Read `AGENTS.md` (standing contract: environment, creds, style, spec conventions),
   `PLAN.md` (architecture §4, decisions ledger §5, phased roadmap §6, grounding facts §2),
   and `NEXT_SESSION.md` (the current iteration brief — Iteration 3 at handoff).
2. `docker compose up -d --wait`, then `bundle exec rspec` and `bundle exec rubocop` —
   the baseline must be green before any work (85 examples, zero offenses at handoff).
3. Checkpoint the uncommitted tree as four Alchemist-style commits (authorized by Ikraam
   for this run):
   - `Added gem foundations and live ClickHouse test environment`
   - `Added read-path type system with live round-trip specs`
   - `Added quoting, server-side binds, and error taxonomy`
   - `Fixed review findings across float, decimal, bind and integer handling`
   Split the files to match each subject honestly; bodies explain WHY (see AGENTS.md).
   Never push, never open a PR.

## Then iterate continuously

Execute `NEXT_SESSION.md`, rewrite it for the next iteration, and keep going:
Iteration 3 (Phase 3: schema statements + migrations) → Iteration 4 (Phase 4: CRUD +
relation semantics) → Iteration 5 (Phase 5: ClickHouse dialect — FINAL, PREWHERE, SAMPLE,
SETTINGS, LIMIT BY, explain) → Iteration 6 (Phase 6: rails-compat harness) → continue
down PLAN.md §6 while quality holds.

## Grounding discipline — stop often and touch reality

- **Red first, live only.** Every behavior gets a failing spec against the real server
  before implementation. Watch it fail. No mocked wire responses, ever.
- **Probe before assuming.** Any wire/server behavior you are not certain of: probe the
  live server first (curl the HTTP interface or a one-off script), add the result to
  PLAN.md §2 grounding facts, then encode it as a spec. The facts table is the project's
  memory — every surprise goes in it.
- **Port from the oracles.** Edge cases come from `../clickhouse/tests/queries/0_stateless`
  (cite the source suite in the spec description) and Rails' own AR suite per PLAN.md §7.
  Skipped upstream cases go in a skip manifest with a one-line reason each — never silently.
- **Grow the e2e spine every iteration.** Maintain `spec/integration/end_to_end_spec.rb`:
  one realistic model exercised through the full stack — create_table migration → model
  class → inserts → relation queries → calculations → `explain` → instrumentation
  (assert `read_rows`/`written_rows` from the response summary once surfaced). Extend it
  with each phase's new capability; it must stay green at every checkpoint.
- **Phase 3 acceptance corpus:** TRMNL core's real migrations in
  `../core/db/migrate_clickhouse/` must run verbatim against this adapter (or each delta
  documented in PLAN.md). That is the definition of "migrations work".
- **Every iteration boundary:** full suite green + rubocop zero + PLAN.md progress/facts
  updated + `NEXT_SESSION.md` rewritten for the next iteration + one Alchemist commit per
  coherent unit (implementation + its specs together).

## Quality bars (from AGENTS.md — enforced, not aspirational)

alchemist-rspec spec style; self-documenting names, no ambiguous abbreviations, no
invented jargon; KISS/YAGNI — every LOC is a liability; no monkeypatches of
ActiveRecord/Arel internals (if one is truly unavoidable: quarantined `compat/` file,
version-guarded, own spec, flagged in the report); runtime deps stay stdlib + activerecord.

## Stop and report instead of pushing through when

- A design fork arises that PLAN.md §5 doesn't answer (e.g. mutation semantics tradeoffs,
  relation-extension seams) — present options with evidence, recommend one, stop.
- The same failure survives two honest fix attempts.
- Correctness would require editing a sibling repo or adding a runtime dependency.
- The rails-compat harness (Phase 6) lands — that is a natural review summit.

## Final report

Iterations completed with per-iteration spec counts; final rspec/rubocop tail output;
every grounding fact added; the commit list; deliberate deferrals with reasons; open
design questions for Ikraam; and the exact state of `NEXT_SESSION.md` for the next run.
