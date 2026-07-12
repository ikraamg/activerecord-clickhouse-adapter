# Iteration 3 (→ ~60%): schema statements + migrations

> Status: ready. Iterations 0–2 reviewed 2026-07-12; the four review findings
> (NaN/Inf→0.0, decimal_class leak into JSON columns, `?` matched inside literals,
> integer binds wrapping mod 2⁶⁴) are fixed with failing-first specs — 85 green, rubocop
> clean. Whole tree still uncommitted.

Read `AGENTS.md` and `PLAN.md` (§4–§6 Phase 3) before writing code. Phases 0–2 are done:
typed reads, quoting, server-side binds, error taxonomy. 72 specs green.

## Mission

Expose ClickHouse schema through Active Record's official seams and support migrations
that look like Rails but speak MergeTree.

Deliverables, in TDD order:

1. **Schema introspection** — `tables` / `views` / `column_definitions` via
   `system.tables` / `system.columns` (never parse `SHOW CREATE`). Indexes via
   `system.data_skipping_indices` where applicable.
2. **Migration DSL** — `create_table engine:, order:, partition:, ttl:, settings:, id:`;
   column `codec:`, `materialized:`, `alias:`, `low_cardinality:`, `nullable:`;
   skip `INDEX ... TYPE bloom_filter`. Default `id: false`; opt-in UUID.
3. **Internal metadata** — `schema_migrations` / `ar_internal_metadata` as
   `ReplacingMergeTree(ver)` with FINAL-reading accessors, via official Rails seams
   (`internal_string_options_for_primary_key`, `schema_versions_formatter`,
   `use_metadata_table`), not prepends.
4. **DatabaseTasks** — create/drop/schema load/dump registration.
5. **Acceptance corpus** — exercise patterns from `../core/db/migrate_clickhouse/` where
   practical (read-only reference).

## Out of scope (resist)

Arel FINAL/SAMPLE/PREWHERE (later phase); RowBinary; write-path bulk insert optimizations;
Nested casting deepening.

## Definition of done

Full suite green; rubocop zero; PLAN.md Phase 3 marked done; this file rewritten for
Iteration 4; session report + proposed commit split. **No commits** unless asked.
