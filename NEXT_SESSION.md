# Iteration 5 (→ ~85%): the ClickHouse dialect

> Status: ready. Iteration 4 landed CRUD (insert_all!, lightweight DELETE, ALTER UPDATE
> mutations, mutations_sync config) and relation coverage incl. cursor batches.
> 146 examples green, rubocop clean, tree committed.

Read `AGENTS.md` and `PLAN.md` (§4–§6 Phase 5) before writing code.

## Goal

The ClickHouse-specific query surface: FINAL, PREWHERE, SAMPLE, LIMIT BY, SETTINGS on
relations, plus a real `explain`.

## Scope

1. **Relation extensions without monkeypatches** (PLAN §9 risk item). Probe the seams
   first: `ActiveRecord::Relation#extending`, adapter-owned Arel nodes, or annotate-based
   passthrough. If per-relation state truly has no public seam, a quarantined
   version-guarded `compat/` prepend with its own spec is the fallback — flag it in the
   session report either way.
2. **Arel visitor support** for `FINAL` (table modifier), `PREWHERE`, `SAMPLE`,
   `LIMIT n BY cols`, `SETTINGS k = v` — each proven live against tables where the
   clause changes results (ReplacingMergeTree duplicates for FINAL; sampled MergeTree
   for SAMPLE with `SAMPLE BY` in DDL).
3. **`Relation#explain`** mapping to `EXPLAIN PLAN/PIPELINE/ESTIMATE/indexes=1`
   (supports_explain? true; `explain(:indexes)` shows primary-key pruning — grounding
   fact already probed). Also plain `.explain` default.
4. **Port targets:** `00409_prewhere*`, sample/limit-by suites from
   `../clickhouse/tests/queries/0_stateless` — cite in spec descriptions.
5. **Grow the e2e spine:** add `.final`-style query (or FINAL fallback), `explain`
   output assertion, and a SETTINGS-scoped query.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md §2/§6 updated + this file rewritten for
Iteration 6 (rails-compat harness — the hard stop for review) + Alchemist commits per
coherent unit. Never push.
