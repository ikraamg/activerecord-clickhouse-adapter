# Iteration 15: relations_test corpus (query-composition semantics at scale)

> Status at handoff: 353 rspec examples green (plus the rails-compat harness: 801
> upstream minitest runs, 0 failures, 91 skips — 17 manifest, 74 capability self-skips),
> rubocop clean. Iteration 13 landed the aggregate-state pipeline (ledger #29): `merge:`
> and `if:` on all aggregate methods, grouped merged reads, parametric type labels in
> the parser, e2e spine chapter for events → MV → AggregatingMergeTree → merged read.
> Iteration 14 landed the dialect fidelity sweep (ledger #30–#32): `array_join`,
> per-write relation settings, `codec:`/`materialized:`/`alias:` columns,
> `primary_key:`/`sample:` table clauses, and partition lifecycle verbs.

## Scope

1. **Vendor `relations_test`** (v8.1.3, byte-exact) — the biggest remaining read-path
   corpus: merge/or/not, unscope, rewhere, structurally-compatible relations. Walk the
   transitive `require`s one at a time as before. Expect manifest skips clustered on
   the known server semantics (GROUP BY functional dependency, self-join ambiguity).
2. **Schema slice growth rules stay decisions #14/#15** plus the Iteration 10/11
   additions: synthesized `order: "id"` Int64 ids, columns `null: true` unless in the
   sorting key, FK columns `limit: 8`, never a column named like its own table,
   `PRIMARY_KEYS` nil-entries for models that must stay pk-less.
3. **Grow the e2e spine** with whatever lands (relation merge/or round trip).
4. If touching the read/write path, re-run `bundle exec ruby benchmarks/round_trip.rb`
   and append to `benchmarks/BASELINE.md` history.

## Watch out for

- The mutation affected-row count is a pre-mutation `SELECT count()` (decision #24):
  raw-SQL mutations and LIMIT/ORDER statements return 0. Don't "fix" upstream tests
  that assert counts on those paths — check what the statement actually was first.
- `return_value_after_insert?` is false for every column (decision #25). Upstream
  tests asserting DB-computed defaults appear on the record without reload need
  manifest skips (no RETURNING), not adapter changes.
- Sorting-key columns are immutable (CANNOT_UPDATE_COLUMN, code 420) — updating a
  record's id can never work; skip with that reason.
- ClickHouse has no correlated subqueries: mutation SET values referencing the target
  table's own columns raise UNKNOWN_IDENTIFIER (code 47).
- `.rollup` totals are keyed `nil` except for LowCardinality group columns, which keep
  their type default (`''`) — group_by_use_nulls doesn't null them (ledger #26).
- `merge:` and `if:` cannot combine (no -MergeIf); state argument types are invariant
  (code 70) — a wrong-typed merge is a server error, not a silent zero.
- Remaining OLAP deferrals: RowBinary + `insert_stream` (dedicated performance
  iteration; PLAN §6 Phase 8 note), window functions, dictionaries/dictGet,
  ON CLUSTER DDL, projections in schema.rb (structure.sql carries them today).
- Fixture YAMLs with ERB (`<%= %>`) evaluate in the harness — keep the vendored files
  byte-exact and let them run.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries (and shrank where workarounds landed),
this file rewritten for Iteration 16.
