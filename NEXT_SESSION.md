# Iteration 4 (→ ~75%): CRUD + relation semantics

> Status: ready. Iteration 3 landed schema statements, the migration DSL, internal
> metadata tables, the migration flow, and the TRMNL corpus acceptance run (16 real
> migrations verbatim, up and down). 122 examples green, rubocop clean, tree committed.

Read `AGENTS.md` and `PLAN.md` (§4–§6 Phase 4) before writing code.

## Goal

Make the write path and relation semantics honest and complete: models can insert
(single and bulk), delete, and mutate; relations cover the everyday query surface.

## Scope

1. **insert_all / upsert semantics.** `Model.insert_all` should batch into a single
   INSERT (VALUES with binds or FORMAT JSONEachRow — probe which is better).
   `upsert`/`insert_all unique_by:` must raise `NotImplementedError`-style errors
   honestly (no fake `supports_insert_on_duplicate_*`).
2. **delete/delete_all** → lightweight `DELETE FROM` (works on 25.8; the Arel visitor
   already unqualifies WHERE columns). `Model.delete_all` with no WHERE needs
   `DELETE FROM t WHERE 1` or TRUNCATE — probe; bare `DELETE FROM t` is code 62.
3. **update/update_all** → `ALTER TABLE ... UPDATE` mutation (probed working with
   `mutations_sync=1`). Expose `mutations_sync` as adapter config so specs are
   deterministic. `Model#update` on a record without a primary key raises — document
   the semantics for pk-less models (update_all with explicit WHERE is the API).
4. **Relation coverage:** find_by/exists?/distinct/limit/offset/or/not, calculations
   (sum/minimum/maximum on Decimal columns — overflow semantics), pluck of multiple
   columns, `in_batches`/`find_each` keyed on ORDER BY columns (no id!) — probe what
   Rails does with `batches` on pk-less tables and decide the seam.
5. **Grow the e2e spine** (`spec/integration/end_to_end_spec.rb`): add bulk insert,
   delete, update_all, and instrumentation assertions (read_rows/written_rows from the
   summary — surface via notifications payload if cheap, else defer to Phase 7).
6. **Port targets:** Rails `insert_all_test`, `calculations_test`, `finder_test`
   selected cases; ClickHouse `02319_lightweight_delete*` suites. Cite sources in spec
   descriptions; start `spec/rails_compat/skips.yml` for skipped upstream cases.

## Boundary checklist

Full suite green + rubocop zero + PLAN.md §2/§6 updated + this file rewritten for
Iteration 5 (dialect: FINAL/PREWHERE/SAMPLE/SETTINGS/LIMIT BY/explain) + Alchemist
commits per coherent unit. Never push.
