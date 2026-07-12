# Iteration 6 (→ review summit): rails-compat harness

> Status: ready. Iteration 5 landed the dialect surface (.final/.sample/.prewhere/
> .settings/.limit_by via opt-in Querying concern + custom Arel nodes) and
> Relation#explain with all four variants. 167 examples green, rubocop clean, committed.

Read `AGENTS.md` and `PLAN.md` (§4–§6 Phase 6) before writing code.

**This iteration ends with a hard stop for Ikraam's review — do not start Phase 7.**

## Goal

A repeatable harness that runs Rails' own Active Record suite against this adapter and
turns the result into a ratcheting pass/skip manifest.

## Scope

1. **Harness skeleton** (`spec/rails_compat/`): a runner that boots selected minitest
   files from `../rails-main/activerecord/test` (pinned SHA — record it) with our
   connection config, non-transactional fixtures, and table truncation between tests.
   Start narrow: `cases/adapter_test.rb`-style smoke, then `basics_test`.
2. **skips.yml manifest**: every skipped upstream test gets a one-line reason
   ("needs unique PK", "needs transactions", "MySQL-specific"...). Green = pass or
   manifest-documented skip. The manifest may only shrink.
3. **Fixture strategy probe**: Rails fixtures INSERT with multi-row VALUES and
   disable/re-enable referential integrity — probe what breaks on ClickHouse and
   document.
4. **Schema translation**: the AR suite's schema.rb uses `t.integer`/`t.string` with
   implicit ids — decide per-suite whether to synthesize `order:` (e.g. first column)
   or skip; document the rule in PLAN.md.
5. **Grow the e2e spine** if any new capability lands en route.

## Stop conditions (from AUTONOMOUS_RUN.md)

The harness landing IS the review summit. Also stop on: design forks PLAN §5 doesn't
answer, a failure surviving two honest fix attempts, sibling-repo edits, new runtime deps.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md updated + this file rewritten for the
post-review iteration + Alchemist commits per coherent unit + the full final report
format from AUTONOMOUS_RUN.md. Never push.
