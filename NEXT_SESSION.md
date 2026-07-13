# Iteration 12: relations_test corpus (query-composition semantics at scale)

> Status at handoff: 252 rspec examples green (incl. the rails-compat harness: 801
> upstream minitest runs, 0 failures, 91 skips — 17 manifest, 74 capability self-skips),
> rubocop clean. Iteration 11 landed the UTC-always `quoted_date` (decision #23 — erased
> both default_timezone :local skips), client-side affected-row counts for mutations
> (decision #24 — update_all/delete_all counts, update_columns booleans, and optimistic
> locking now honest), the returning/write-back fix (decision #25 — a default-function
> column was swallowing the generated pk), free-form sequence labels in
> next_sequence_value (Oracle legacy, `companies_nonstd_seq`), `change_column_default`
> (MODIFY COLUMN ... DEFAULT / REMOVE DEFAULT), and the persistence_test corpus
> (+12 models incl. `admin/`, +3 fixture sets, +8 slice tables).

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
- The legacy analyzer (`enable_analyzer=0`) would fix the self-join and
  qualified-matcher skips but is deprecated — decision made in Iteration 11 not to
  pin it. Don't revisit without new server-side evidence.
- Fixture YAMLs with ERB (`<%= %>`) evaluate in the harness — keep the vendored files
  byte-exact and let them run.

## Definition of done

Full suite green (authored + harness), rubocop zero, PLAN.md §2/§5/§6 updated,
skips.yml only grew by honestly-reasoned entries (and shrank where workarounds landed),
this file rewritten for Iteration 13.
