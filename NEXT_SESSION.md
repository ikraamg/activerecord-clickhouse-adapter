# Iteration 22: release mechanics, or the next corpus

> Status at handoff: 487 rspec examples green plus the rails-compat harness at
> **2,226 upstream runs, 0 failures, 177 skips**, rubocop clean. Iteration 21
> closed the AR-parity gaps in the alter surface (rename_column, change_column,
> change_column_null with backfill, comments, post-create indexes,
> create_join_table sorting-key default — ledger #47) and made dictionaries
> first-class citizens of both dump formats (cross-database `database:` kwarg,
> credential-safe schema.rb + structure.sql round-trips — ledger #48/#49).

## Scope

Pick one (value order):

1. **0.1.0 release mechanics** if Ikraam green-lights: tag, push, `gem push`
   (needs credentials — stop and ask). CI gets its first real run on push.
2. **Next corpus:** `migration_test` is now worth attempting — the alter surface
   it exercises exists as of this iteration. Alternatively
   `autosave_association_test` or the `scoping` suites.
3. **Dialect deepening:** ON CLUSTER for the dialect verbs (projections,
   partitions, OPTIMIZE, dictionaries); dictionary layouts beyond FLAT/HASHED
   (complex_key_*, range_hashed) when a consumer shape shows up.

## Watch out for (carried forward + new)

- The Docker VM killed the ClickHouse container mid-harness once this iteration
  (exit 137 = OOM/SIGKILL, ~15.6 GiB VM). A fresh `docker compose down && up`
  and rerun was clean. If harness runs start dying with "Connection refused",
  check `docker ps` before debugging the adapter.
- `change_column_null(…, false)` narrows the real stored type: it re-reads
  sql_type and strips one Nullable wrapper. Narrowing with stored NULLs is a
  server error (code 349) unless the Rails backfill default is passed — that
  runs as a `mutations_sync = 1` ALTER UPDATE first (§2).
- `change_column` builds MODIFY COLUMN from scratch: type wrappers
  (Nullable/LowCardinality) come from options, not from the previous column, so
  omitting `null: true` on a nullable column makes it non-nullable — same
  semantics as Rails on other adapters (change_column replaces the definition).
- structure_load rewrites USER/PASSWORD inside CREATE DICTIONARY statements
  with the loading connection's credentials — if a dictionary should
  authenticate as someone else, that's not expressible yet.
- The compose file runs an embedded Keeper (`spec/support/cluster/keeper.xml`);
  a stale container predating Iteration 20 fails the on_cluster spec with
  NO_ELEMENTS_IN_CONFIG.
- CI is untested against real GitHub Actions — the first push will tell.
- HAVING resolves SELECT aliases first (§2); raw DML without WHERE is a syntax
  error (`raw_update_without_where`/`raw_delete_without_where` anchors);
  `self_join_ambiguity` anchor for unaliased base tables in self-joins.
- DateTime reads follow `default_timezone` (ledger #42); writes always encode
  UTC (ledger #23).
- Rails' prefetch seam cannot populate one column of a composite primary key —
  skip, don't special-case.
- Core-port follow-ups: the `~/Documents/GitHub/core.worktrees/adapter-port`
  worktree holds the uncommitted core-side edits — Ikraam decides if/when that
  becomes a core PR.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries, benchmarks re-run if the
read/write path was touched, this file rewritten for Iteration 23.
