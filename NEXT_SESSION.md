# Iteration 2 (→ ~40%): quoting, server-side binds, error taxonomy

> Status: ready for next session. Review checkpoint after Iteration 1 (type system) first.

Read `AGENTS.md` and `PLAN.md` (§4 architecture, §5 decisions ledger, §6 Phase 2)
before writing any code. Phase 0+1 are done: adapter registers, HTTP JSONCompact read
path casts every supported family, 58 specs green, rubocop clean.

## Mission

Ruby values round-trip into SQL safely, binds go to the server as typed `{name:Type}`
parameters (no client-side interpolation), and ClickHouse exception codes become real
Active Record errors.

Deliverables, in TDD order:

1. **`ClickHouse::Quoting`** — quote strings, dates/times, bools, arrays, tuples, maps,
   `NULL` / `\N` semantics as needed for HTTP. Prove with live `SELECT {literal}` round-trips
   and injection-style payloads (`'; DROP`, embedded quotes, unicode).
2. **Server-side binds** — Arel collector emits `{p0:UInt64}` (etc.); HTTP layer sends
   `param_p0=...`. `select_value("SELECT ? + 1", [41])` / bind-bearing relation queries work.
   Fallback to quoted literals only where a type can't be inferred. Spec: injection payload
   as a *bound value* must not alter SQL structure.
3. **Error taxonomy** — map `X-ClickHouse-Exception-Code` via
   `../clickhouse/src/Common/ErrorCodes.cpp`: 60/81 → unknown table/database subtypes,
   241 → memory limit, 159/160 → timeout, 516 → auth, connection refused →
   `ConnectionNotEstablished`. Mid-stream failure: keep `wait_end_of_query=1` on selects
   so HTTP status stays honest (decision §5.9).
4. **Grounding** — extend PLAN.md facts with anything the server teaches; rewrite this file
   as the Iteration 3 brief (schema statements + migrations).

## Out of scope (resist)

Schema/migrations (Iteration 3); write-path inserts; RowBinary; Nested/geometry casting
deepening; NaN/Inf settings; performance work.

## Definition of done

Full suite green against live 25.8; rubocop zero; PLAN.md Phase 2 marked done; this file
rewritten for Iteration 3; session report with proposed Alchemist commit split. **No commits**
unless Ikraam asks.
