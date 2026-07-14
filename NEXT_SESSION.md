# Iteration 21: release mechanics, or the next corpus

> Status at handoff: 465 rspec examples green plus the rails-compat harness at
> **2,226 upstream runs, 0 failures, 177 skips** (all manifest-documented or
> capability self-skips), rubocop clean. Iteration 20 shipped the two
> through-association corpora (223 new runs, zero adapter gaps), dictionaries
> (`create_dictionary` + `.dict_get`, ledger #44), ON CLUSTER DDL via `cluster:`
> config with an embedded Keeper in the compose file (ledger #45), and
> projections dumping into schema.rb as `add_projection` lines (ledger #46).

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, push, `gem push`
   (needs credentials — stop and ask). CI gets its first real run on push.
2. **Next corpus:** `autosave_association_test`, `scoping` suites, or
   `query_cache_test` — each exercises seams no current suite reaches
   (autosave ordering, default_scope merging, cache invalidation on raw writes).
3. **Dialect deepening:** stamp ON CLUSTER onto the dialect DDL verbs
   (projections, partitions, OPTIMIZE, dictionaries) once a real multi-node
   consumer needs it; or dictionary layouts beyond FLAT/HASHED (complex_key,
   range_hashed) if a consumer shape shows up.

## Watch out for (carried forward + new)

- The compose file now runs an embedded Keeper (`spec/support/cluster/keeper.xml`)
  so ON CLUSTER DDL works on one node — a stale container predating Iteration 20
  fails the on_cluster spec with NO_ELEMENTS_IN_CONFIG; `docker compose down &&
  up` fixes it.
- `create_dictionary` writes the adapter's USER/PASSWORD into SOURCE(CLICKHOUSE(…))
  because the dictionary loader authenticates separately (§2). If a consumer's
  dictionary source lives in another database, the DB clause already points at
  the connection's database — cross-database sources would need a new kwarg.
- ReplacingMergeTree refuses ADD PROJECTION under the default
  `deduplicate_merge_projection_mode = 'throw'` (§2) — don't "fix" the dumper,
  it's a server-side table setting.
- The schema dumper parses projection kwargs out of `system.projections` query
  text; a projection created outside add_projection with exotic formatting
  (subqueries, newlines) still round-trips as long as SELECT/GROUP BY/ORDER BY
  appear in that order.
- CI is untested against real GitHub Actions — the first push will tell. The
  committed lock includes bcrypt (test-only, for `models/user`).
- The harness shim now includes upstream's `validations_repair_helper`
  (`repair_validations` teardown) — new suites relying on more of upstream's
  helper.rb should port pieces into `spec/rails_compat/support/cases/helper.rb`.
- HAVING resolves SELECT aliases first (§2): a projected `SUM(x) AS x` makes
  `HAVING SUM(x)` nested (ILLEGAL_AGGREGATION) — manifest skip, don't rewrite.
- Raw `delete from t` / `update t set ...` without WHERE are syntax errors on
  ClickHouse (§2) — `raw_delete_without_where` / `raw_update_without_where`
  skip anchors exist; `self_join_ambiguity` is now anchored too.
- DateTime reads: representation follows `default_timezone` (ledger #42); writes
  still always encode UTC (ledger #23). Don't "fix" one by breaking the other.
- The read wire is RowBinary. Any new server type shows up as
  `RowBinary::Undecodable` → silent JSON fallback per query.
- Rails' prefetch seam cannot populate one column of a composite primary key —
  cpk models whose slice table has a single-column sorting key hit
  `next_sequence_value(nil)`; skip, don't special-case.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420); no
  correlated subqueries in mutation SETs (UNKNOWN_IDENTIFIER, code 47).
- Core-port follow-ups: the `~/Documents/GitHub/core.worktrees/adapter-port`
  worktree holds the uncommitted core-side edits — Ikraam decides if/when that
  becomes a core PR.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 22.
