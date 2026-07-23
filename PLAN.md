# activerecord-clickhouse-adapter — Implementation Plan

A fully featured, high-performance Active Record adapter for ClickHouse. Accuracy and beauty
over speed of delivery: every behavior is proven against a **real ClickHouse server**, every
performance claim is measured, and the adapter uses Rails' official extension points — no
monkeypatches into Active Record or Arel internals.

## 1. Mission and principles

- **Real-server TDD.** No mocked wire responses. The spec suite talks to a live
  `clickhouse-server` (docker compose in this repo). Red first, then green.
- **Ports of authority.** Correctness is defined by two upstream corpora:
  Rails' Active Record test suite (`../rails-main/activerecord/test`) and ClickHouse's
  stateless SQL tests (`../clickhouse/tests/queries/0_stateless`). We port, we don't invent.
- **No monkeypatches.** Rails 8.1+ gives official seams: `ConnectionAdapters.register`,
  `AbstractAdapter` subclassing with the `perform_query`/`cast_result`/`affected_rows`
  pipeline, per-adapter Arel visitors, `NATIVE_DATABASE_TYPES`, `DatabaseTasks.register_task`.
  The prior-art gem reopens Rails internals; we will not.
- **Performance is a feature.** Server-side bind parameters, persistent HTTP with
  compression, a pluggable wire-format codec (`RowBinary` by default, JSON as the
  correctness fallback), streamed bulk inserts, and a benchmark suite with committed
  baseline numbers.
- **Instrumentation is first-class.** ClickHouse tells us `read_rows`, `read_bytes`,
  `elapsed_ns` on every response (`X-ClickHouse-Summary`); the adapter surfaces that through
  `ActiveSupport::Notifications` and `Relation#explain` maps to real `EXPLAIN` variants.

## 2. Grounding facts (verified live, 2026-07-12)

Server: `clickhouse/clickhouse-server:25.8` (LTS; reports `25.8.28.1`, timezone UTC) on
`localhost:18123` via this repo's `docker-compose.yml`.

| Fact | Evidence |
|---|---|
| `JSONCompactEachRowWithNamesAndTypes` returns names line, types line, then row arrays | probed: `["one","big","ts","arr","n"]` / `["UInt8","Int64","DateTime64(3, 'UTC')","Array(String)","Nullable(Nothing)"]` |
| Int64 > 2^53 arrives as an exact unquoted JSON number; Ruby `JSON.parse` preserves it | probed with `9007199254740993` |
| Server-side query parameters work over HTTP | `SELECT {n:UInt64} + 1` + `param_n=41` → `42` |
| Every response carries `X-ClickHouse-Summary` (`read_rows`, `read_bytes`, `written_rows`, `elapsed_ns`) and `X-ClickHouse-Query-Id` | probed |
| Lightweight `DELETE FROM t WHERE ...` works on 25.8 | probed |
| Lightweight `UPDATE` needs table setting `enable_block_number_column=1` (+ experimental flag) on 25.8, else `ALTER TABLE ... UPDATE` mutations | probed: NOT_IMPLEMENTED error text |
| `EXPLAIN indexes=1` shows primary-key pruning per query | probed |
| Decimal arrives as an **unquoted JSON number** by default — Float precision trap; `output_format_json_quote_decimals=1` → exact quoted strings, including inside `Array(Decimal)` | probed: `Decimal(38,10)` → `"12345678901234567890.1234567891"` quoted, `["1.5"]` in arrays |
| `NaN`/`±Inf` Floats arrive as `null` by default (data loss); `output_format_json_quote_denormals=1` → `"nan"` / `"inf"` / `"-inf"` strings | probed |
| Map keys arrive as JSON-object **string** keys regardless of key type — key caster must cast back | probed: `Map(UInt64, String)` → `{"1":"a"}` |
| Unnamed Tuple → JSON array; named Tuple → JSON object keyed by element names | probed: `[1,"x"]` vs `{"a":1,"b":"x"}` |
| Enum values arrive as their string **labels**, not numeric values | probed: `Enum8('a'=1,'b'=2)` → `"b"` |
| FixedString(N) arrives NUL-padded to N (`"ab\u0000\u0000\u0000"`); padding is kept for binary fidelity | probed |
| Invalid UTF-8 in String columns passes through as **raw bytes** (no U+FFFD replacement) — Ruby-side JSON parsing of such bodies needs explicit handling; full binary fidelity waits for RowBinary | probed: `char(0xC3)` → raw `0xC3` byte in body |
| `JSON.parse(line, decimal_class: BigDecimal)` keeps Decimal(38,10) exact; Floats also become BigDecimal and must `.to_f` in the Float caster | Iteration 1 live |
| Named `Tuple(n UInt8, s String)` arrives as a JSON object; positional `Tuple(UInt8, String)` as a JSON array | Iteration 1 live |
| `toTypeName` may pretty-print named Tuples with newlines/indentation | Iteration 1 live |
| `Date` clamps below 1970-01-01; use `Date32` for 1900–2299 | Iteration 1 live |
| UInt256 max must be passed as a String literal — unquoted numerics lose precision server-side | Iteration 1 live |
| NaN/Inf arrive as JSON `null` unless `output_format_json_quote_denormals=1` (deferred) | Iteration 1 probe |
| Ruby `gsub("'", "\\'")` is wrong — `\'` in replacement means post-match; use a block | Iteration 2 |
| `wait_end_of_query=1` keeps HTTP status honest for select errors | Iteration 2 |
| Exception codes 60/81/516 verified live as UNKNOWN_TABLE / UNKNOWN_DATABASE / AUTHENTICATION_FAILED | Iteration 2 |
| `INSERT ... VALUES ({p:Type})` accepts server-side params like SELECT does | Iteration 3 probe |
| Lightweight `DELETE` rejects table-qualified WHERE columns (`t.col` → code 47 UNKNOWN_IDENTIFIER against the mutation's internal projection); Arel visitor emits bare names in deletes | Iteration 3 live |
| `ALTER TABLE ... UPDATE` works with `mutations_sync=1` as an HTTP param | Iteration 3 probe |
| `SHOW CREATE TABLE` normalizes `INTERVAL 30 DAY` → `toIntervalDay(30)` | Iteration 3 live |
| `system.columns.default_expression` returns string literals quoted (`'none'`), function defaults verbatim (`now64(3)`) | Iteration 3 live |
| Without a Rails env, `InternalMetadata` records environment as the db_config `env_name` (`default_env` for a plain hash config) | Iteration 3 live |
| TRMNL corpus needs `inflect.acronym "TTL"` (app inflection) for `ReduceLogsTTLToFourteenDays` to resolve | Iteration 3 live |
| Bare `DELETE FROM t` / `ALTER TABLE t UPDATE ...` without WHERE are syntax errors (code 62) — the visitor appends `WHERE 1` when unscoped | Iteration 4 live |
| `mutations_sync=1` as a per-request HTTP param makes mutations block until applied | Iteration 4 live |
| Rails `insert_all` implies duplicate-skip; with no unique constraints the skip is vacuous, so `supports_insert_on_duplicate_skip? = true` emits a plain INSERT (revised from Iteration 4's `false` while porting TRMNL core — ledger #39) | Iteration 17 live |
| ClickHouse rejects trailing `/*...*/` comments after `INSERT ... VALUES` (code 27, ValuesBlockInputFormat parses the tail); leading comments are fine — Rails QueryLogs' sqlcommenter tags must be hoisted | Iteration 17 live |
| Bundler evaluates a path/git gem's gemspec at `bundler/setup` time; a gemspec `require_relative` that defines any `ActiveRecord` constant clobbers active_record.rb's `autoload :ConnectionAdapters` and breaks every later adapter require | Iteration 17 live |
| `connection.migration_context` is gone in AR 8.1 — it lives on `connection_pool.migration_context` (TRMNL core's rake task assumed the old seam) | Iteration 17 live |
| clickhouse-activerecord's `schema_migrations` state is not interoperable: it records versions in a ReplacingMergeTree with `active` flags, so a sink it migrated reports missing versions to this adapter — factory-reset before switching | Iteration 17 live |
| `ssl: true` verifies certificates (Net::HTTP default); `ssl_verify: false` is the escape hatch for self-signed sinks — proven against the compose file's HTTPS listener (18443, self-signed cert in spec/support/tls) | Iteration 17 live |
| Backtick-quoted identifiers accept `$`, unicode (`なまえ`) and reserved words (`from`) as column names — DDL, INSERT and SELECT all round-trip them | Iteration 18 probe |
| HAVING resolves identifiers to SELECT aliases first: projecting `SUM(salary) AS salary` makes `HAVING SUM(salary)` a nested aggregate (ILLEGAL_AGGREGATION, code 184) | Iteration 19 live |
| Lightweight `DELETE` requires a WHERE clause (bare `delete from t` is a SYNTAX_ERROR), same as `ALTER ... UPDATE` | Iteration 19 live |
| `lag`/`lead` work directly as window functions on 25.8 (no `lagInFrame` + explicit frame dance); ROWS/RANGE/GROUPS frames all parse | Iteration 19 probe |
| `find_each(cursor: [...])` (Rails 8.1) batches pk-less tables over explicit ORDER BY columns | Iteration 4 live |
| Clause grammar: `FROM t [FINAL] [SAMPLE f] PREWHERE ... WHERE ... ORDER BY ... LIMIT n BY cols LIMIT m SETTINGS ...` — `LIMIT m` before `LIMIT n BY` is a syntax error | Iteration 5 live |
| `FINAL` on a non-replacing MergeTree raises code 181; `SAMPLE` without `SAMPLE BY` in DDL raises code 141 | Iteration 5 probe |
| `EXPLAIN` / `EXPLAIN PIPELINE` / `EXPLAIN ESTIMATE` / `EXPLAIN indexes = 1` all return single-String-column result sets over HTTP | Iteration 5 probe |
| minitest 6 (Ruby 4 default) extracted `minitest/mock` to a separate gem — Rails 8.1 test helpers need minitest ~> 5.25 | Iteration 6 |
| `enable_http_compression=1` gzips response bodies ~3.6x smaller (789 KB → 216 KB on a 100k-row select); Net::HTTP sends `Accept-Encoding: gzip` by default and decompresses transparently, **including error bodies** | Iteration 7 probe |
| `count()` on MergeTree is answered from metadata (`optimize_trivial_count_query`): summary reports `read_rows: 1` — instrumentation assertions need a real column aggregation | Iteration 7 live |
| Wire DateTime shape is always `YYYY-MM-DD HH:MM:SS[.fraction]`; `zone.local` on regexp captures is 3.3x faster than `zone.parse` and was the read path's top allocator (17.7 of 43.2 MB per 10k-row select) | Iteration 7 benchmark |
| String HTTP query params use the escaped format: `\n`/`\t`/`\r`/`\0`/`\` must be sent as `\\n`/`\\t`/`\\r`/`\\0`/`\\\\`, else "cannot be parsed as String ... isn't parsed completely" (code 457) | Iteration 8 probe |
| Default `join_use_nulls=0` fills unmatched LEFT JOIN columns with type defaults (0, ''), not NULL — breaks Rails aggregate semantics; adapter now sends `join_use_nulls=1` by default (configurable) | Iteration 8 live |
| `system.tables.engine_full` carries the full `ENGINE ... PARTITION BY ... ORDER BY ... TTL ... SETTINGS ...` clause chain, splittable on clause keywords for the schema dumper | Iteration 8 live |
| No functional-dependency GROUP BY: `SELECT t.* GROUP BY t.id` raises NOT_AN_AGGREGATE (code 215) even when id is the primary key | Iteration 8 live |
| Self-join with an unaliased base table (`FROM topics JOIN topics AS replies_topics ON ...`) raises AMBIGUOUS_IDENTIFIER (code 207) | Iteration 8 live |
| Database-level DDL error codes verified live: 82 DATABASE_ALREADY_EXISTS, 81 UNKNOWN_DATABASE | Iteration 8 live |
| Rails' default `insert_fixtures_set` issues bare `DELETE FROM t` (syntax error here) inside a transaction; the adapter overrides it with TRUNCATE + per-table batched INSERTs | Iteration 8 live |
| `create!` without an explicit id stores the column default (0) and leaves the AR object's id nil — no autoincrement, no `INSERT ... RETURNING`; solved by client-side prefetch (decision #18) | Iteration 8 live |
| Rails always requests the primary key back via `returning:` (`_returning_columns_for_insert` falls back to `Array(primary_key)`), so `#insert` must surface the prefetched id as the returning row or `create!` leaves id nil | Iteration 9 live |
| A boolean column default (`DEFAULT true`) arrives in `system.columns.default_expression` as the bare token `true`; classifying it as a default_function made `Column#auto_populated?` true and broke the pk write-back (Rails asked RETURNING for it) | Iteration 9 live |
| VALUES-section coercion: a `now64(6)` expression (internally Decimal64) raises TYPE_MISMATCH (code 53) against Date32 columns, and even `toString(now64(6))` will not parse into Date32; only plain `now()` (DateTime) coerces into both Date32 and DateTime64 targets | Iteration 9 probe |
| Sorting keys reject Nullable columns by default (`allow_nullable_key` off, ILLEGAL_COLUMN code 44) — schema-slice tables keyed on foreign keys must keep those columns non-nullable | Iteration 9 live |
| `Nullable(Nothing)` is the one query-param type that carries NULL (sent as `\N`) and still compares against any column type; a nil bind typed e.g. `Nullable(String)` with an empty value silently becomes `''`, not NULL | Iteration 10 probe |
| A column named like its own table breaks the qualified matcher: `SELECT comments.* FROM comments WHERE ...` resolves `comments` to the column and raises UNSUPPORTED_METHOD (code 1) — only when a WHERE/ORDER clause is present | Iteration 10 probe |
| DateTime64 query params reject timezone offsets ("isn't parsed completely", code 457): values must be naive wall-clock strings, so `default_timezone = :local` cannot round-trip | Iteration 10 probe |
| `RENAME TABLE a TO b` is plain ClickHouse DDL and preserves rows — backs `rename_table` | Iteration 10 live |
| Mutations (`ALTER TABLE ... UPDATE`, lightweight `DELETE`) report no affected-row count: `X-ClickHouse-Summary` stays all zeros even with `wait_end_of_query=1` + `mutations_sync=1` | Iteration 11 probe |
| Sorting-key columns are immutable: `ALTER TABLE ... UPDATE id = ...` raises CANNOT_UPDATE_COLUMN (code 420) | Iteration 11 live |
| A mutation SET value cannot reference the target table's own columns through a correlated subquery — UNKNOWN_IDENTIFIER (code 47); ClickHouse has no correlated subqueries | Iteration 11 live |
| `ALTER TABLE t MODIFY COLUMN c DEFAULT expr` changes a default without restating the type; `... REMOVE DEFAULT` drops it — backs `change_column_default` | Iteration 11 probe |
| The legacy analyzer (`enable_analyzer=0`) resolves both the unaliased self-join and the table-named-column qualified matcher that the new analyzer rejects, but still lacks functional-dependency GROUP BY; pinning a deprecated analyzer is not a workaround worth shipping | Iteration 11 probe |
| `WITH TOTALS` emits its row out-of-band: `JSONCompact` carries a separate `totals` field and `JSONCompactEachRowWithNamesAndTypes` drops the row entirely; `WITH ROLLUP` delivers totals as ordinary in-band rows | Iteration 12 probe |
| `group_by_use_nulls=1` keys ROLLUP/CUBE total rows with NULL — except LowCardinality group columns, which keep their type default (`''`/`0`) | Iteration 12 probe |
| `ORDER BY ... WITH FILL STEP INTERVAL n unit` fills DateTime gaps; `FROM`/`TO` bounds raise INVALID_WITH_FILL_EXPRESSION (code 475) when the literal's type doesn't match the column exactly | Iteration 12 probe |
| `system.tables` exposes a materialized view's `as_select` and `create_table_query` (TO target parseable); `DROP TABLE` works on views; the stored SQL database-qualifies every identifier | Iteration 12 probe |
| `async_insert`/`wait_for_async_insert` work as HTTP query params per request; `wait_for_async_insert=1` blocks the ack until the buffer flushes, so the row is immediately readable | Iteration 12 probe |
| Rails' stock batching shape (`WHERE pk > last ORDER BY pk LIMIT n`) prunes via PrimaryKey binary search per EXPLAIN — no custom find_each needed when pk = sorting key | Iteration 12 probe |
| `INSERT INTO t (cols) SETTINGS k = v VALUES ...` is valid — SETTINGS sits between the column list and VALUES | Iteration 12 probe |
| AggregateFunction state argument types are invariant: merging a state built from one type into another raises CANNOT_CONVERT_TYPE (code 70); states arrive as opaque binary strings on the JSON wire, SimpleAggregateFunction reads cast to the inner type | Iteration 13 probe |
| Parametric combinators keep parameters inside the type label — `AggregateFunction(quantile(0.95), Int64)` — so the type parser must treat the function name as balanced-paren text, not a bare identifier | Iteration 13 live |
| `system.columns.default_kind` distinguishes DEFAULT / MATERIALIZED / ALIAS with the expression in `default_expression`; `compression_codec` carries `CODEC(...)` verbatim | Iteration 14 probe |
| `system.tables.primary_key` equals `sorting_key` unless a narrower PRIMARY KEY clause was declared — the inequality is the only dump-worthy signal | Iteration 14 probe |
| `ALTER TABLE ... {DETACH\|ATTACH\|DROP\|FREEZE} PARTITION ID '<id>'` takes a plain quoted literal — the ID form never evaluates expressions, unlike `PARTITION <expr>` | Iteration 14 probe |
| With 2+ JOINs the analyzer renames a qualified star's colliding columns to `table.column` on the wire (first duplicate stays bare, later ones qualify); no setting restores bare names — `multiple_joins_try_to_keep_original_names` is old-analyzer only | Iteration 15 probe |
| A column named like its own table breaks every qualified star: `SELECT t.* FROM t` resolves `t.*` to the column, raising UNSUPPORTED_METHOD (code 1) | Iteration 15 probe |
| A FROM alias equal to a real table name shadows that table in later JOINs — `FROM posts AS categories_posts JOIN categories_posts` joins the aliased posts again (UNKNOWN_IDENTIFIER, code 47) | Iteration 15 probe |
| Rails opens a SavepointTransaction for `transaction(requires_new: true)` nested in a dirty transaction regardless of `supports_savepoints?` — clean parents get RestartParentTransaction instead, so only dirty nesting reaches `create_savepoint` | Iteration 15 live |
| Mutations with ORDER/LIMIT arrive as `WHERE pk IN (SELECT ...)` (Rails' Arel rewrite), so the pre-mutation count must run the same subquery; stripping qualifiers inside that subquery makes JOIN ONs ambiguous (AMBIGUOUS_COLUMN_NAME, code 352) | Iteration 16 live |
| RowBinary encodes everything little-endian: varint-prefixed Strings, UUID as two LE UInt64 halves (high, low), Date UInt16 / Date32 Int32 epoch days, DateTime UInt32 epoch seconds, DateTime64 Int64 ticks, Decimal as scaled Int32/64/128/256 by precision (header normalizes aliases to `Decimal(P, S)`), Nullable as a flag byte that omits the payload when null, Map as varint count + interleaved pairs | Iteration 16 probe |
| RowBinary serializes LowCardinality columns as their plain inner type — the dictionary encoding is block-format-only | Iteration 16 probe |
| `output_format_binary_write_json_as_string=1` delivers JSON columns as their text form on binary wires; without it they use a binary layout with no stability guarantee | Iteration 16 probe |
| The HTTP interface accepts chunked `Transfer-Encoding` INSERT bodies with the statement in the `query` param: 100k `JSONCompactEachRow` rows streamed in one request, `written_rows` in the summary header | Iteration 16 probe |
| A dictionary's CLICKHOUSE source authenticates separately from the session that created it — it connects as `default` and fails dictGet with AUTHENTICATION_FAILED (code 516) unless SOURCE carries USER/PASSWORD | Iteration 20 probe |
| ON CLUSTER DDL needs a coordination layer even on the stock single-replica `default` cluster (NO_ELEMENTS_IN_CONFIG, code 139); an embedded Keeper (`keeper_server` + `zookeeper` pointing at itself) suffices | Iteration 20 probe |
| ReplacingMergeTree refuses ADD PROJECTION while `deduplicate_merge_projection_mode = 'throw'` (the default): SUPPORT_IS_DISABLED, code 344 — plain MergeTree takes projections unconditionally | Iteration 20 probe |
| `system.projections` stores each projection's definition as query text (`SELECT ... [GROUP BY ...] [ORDER BY ...]`) plus name/type/sorting_key — enough to round-trip `add_projection` through schema.rb | Iteration 20 probe |
| Narrowing `Nullable(T)` → `T` via MODIFY COLUMN fails on stored NULLs (CANNOT_INSERT_NULL_IN_ORDINARY_COLUMN, code 349, surfacing as UNFINISHED mutation 341) — a backfill must run first | Iteration 21 probe |
| `SHOW CREATE` masks dictionary source passwords as `PASSWORD '[HIDDEN]'` — a structure.sql dump replayed verbatim recreates a dictionary that can never authenticate | Iteration 21 probe |
| `ALTER TABLE ... RENAME COLUMN / MODIFY COLUMN <type> / ADD INDEX / DROP INDEX / COMMENT COLUMN / MODIFY COMMENT` all work on 25.8 with the documented grammar | Iteration 21 probe |
| ClickHouse 26.6 refuses `MODIFY COLUMN Nullable(T) → T` without a `DEFAULT` clause in the statement (BAD_ARGUMENTS, code 36) — and with one, stored NULLs silently become that default; `DEFAULT defaultValueOfTypeName('T')` + `REMOVE DEFAULT` round-trips to the pre-26.6 shape | Iteration 22 probe (26.6.1) |
| ClickHouse 26.x flips the `async_insert` server default to 1, so `getSetting('async_insert')` is no longer false on an unconfigured connection — assert `system.settings.changed = 0` instead | Iteration 22 probe (26.6.1) |
| ClickHouse 26.6 nulls LowCardinality keys under `group_by_use_nulls` (25.8 kept the type default for ROLLUP total rows) — LowCardinality totals now arrive keyed nil like every other type | Iteration 22 probe (26.6.1) |
| ClickHouse 26.6 adds the `Geometry` and `QBit` type families and removes `Object` (the old JSON implementation) from `system.data_type_families` | Iteration 22 probe (26.6.1) |
| After a lazy `String → Nullable(String)` conversion, 25.8's `IS NULL` reads a stale `.null` subcolumn for pre-conversion parts (reports NULL for real values until OPTIMIZE); `SETTINGS optimize_functions_to_subcolumns = 0` reads the true values — mutations are unaffected | Iteration 22 probe (25.8.28) |
| ClickHouse 25.3 (the LTS before 25.8) fails 5 authored specs — both JSON-over-the-wire row_binary cases, `lag` window sugar, the type-family census, and the batching EXPLAIN prune check — so 25.8 is the hard support floor, not a soft default | Iteration 22b probe (25.3.14) |
| ALTER UPDATE type-checks the mutation expression before matching rows: `UPDATE t SET fk = NULL WHERE ...` on a non-Nullable column raises CANNOT_CONVERT_TYPE (code 70) even when zero rows match — row stores no-op instead | Iteration 26 live (25.8.28) |
| The circular-join AMBIGUOUS_IDENTIFIER (base table reappearing under an alias, code 207) holds on 26.6 and under the legacy analyzer (`enable_analyzer=0`) alike — not a new-analyzer quirk, a dialect rule | Iteration 26 probe (25.8.28 + 26.6.1) |
| `Decimal(P, S)` requires `S <= P`: `Decimal(2, 10)` raises ARGUMENT_OUT_OF_BOUND (code 69) at CREATE time; `Decimal(P)` with one argument means scale 0 | Iteration 28 probe (25.8.28) |
| `INSERT INTO t VALUES ()` is a syntax error, but `INSERT INTO t FORMAT JSONEachRow {}` inserts one all-defaults row — the ClickHouse spelling of SQL's `DEFAULT VALUES`, and it needs no column name | Iteration 29 probe (25.8.28) |
| `readonly=1` refuses the adapter's own session settings (join_use_nulls et al.) with code 164 before any query runs; `readonly=2` permits settings changes but still refuses writes — `read_only: true` must stamp 2, not 1 | Iteration 45 probe (25.8.28) |
| Grant checks fire before readonly checks: a SELECT-only user's CREATE TABLE raises 497 ACCESS_DENIED, a fully-granted `readonly=2` user's raises 164 READONLY | Iteration 45 probe (25.8.28) |

Local corpora:

- `../rails-main` — Rails `main` worktree (8.2.0.alpha, pulled 2026-07-12).
- `../clickhouse` — sparse clone (docs, `tests/queries/0_stateless` ≈ 24,660 files,
  `src/DataTypes`, `src/Formats`, `src/Core`).
- `../adapter-reference/` — prior art: `clickhouse-activerecord` (PNixx), `click_house`
  (shlima), `ch` + `ecto_ch` (Plausible's Elixir client/adapter, the best-designed reference),
  `clickhouse-js` (official JS client), `infi.clickhouse_orm` (Python ORM — richest
  field/engine/migrations catalogue), `go-clickhouse` (uptrace — struct models + migrations).
- `../core` — TRMNL Rails app: real-world consumer (Telemetry sinks on `clickhouse-activerecord`
  1.6.7 today) and the eventual end-to-end proving ground.

## 3. What others built, what we take, what we avoid

**PNixx/clickhouse-activerecord** (de facto standard, 258★, used by TRMNL core today).
Proves demand and the overall shape (HTTP, migration DSL with engines, `settings`/`final`
relation methods). The full audit (see git history / chat) found: single mutex-guarded
`Net::HTTP` socket, no compression, no retries, `allow_retry` ignored; binds discarded —
100% client-side interpolation; regex-based type wrapping and type lookup (breaks on nested
types, Enum fallthrough to `:string`); no Tuple/IPv4/6/UInt128/Nested; SSL `VERIFY_NONE`
default; ~12 prepends/reopens of AR & Arel internals with per-Rails-version branches;
`supports_insert_on_duplicate_*` returning `true` with no semantics behind them;
`last_inserted_id → nil`; auto-added `id` column fighting CH's model; `exec_update` always
returning 0; thread-safety scars (response format had to move to a thread-local after a
production race). Each item maps to a design decision below — this list is the negative
space our architecture is drawn around. Two ideas worth *keeping*: test-helper truncation
hooks for consumer apps, and the append-only ReplacingMergeTree metadata-table shape.

**shlima/click_house** — clean plain-Ruby HTTP client + response type casting; good shapes
for a client API, no AR integration.

**plausible/ch + ecto_ch** — the architectural north star: RowBinary codec for both reads and
writes, strict type modules, clean separation of client/adapter. We mirror that separation:
`ClickHouse::HTTPConnection` + format codecs under the adapter namespace, adapter logic above.

**clickhouse-js** — official client; reference for settings passthrough, session handling,
and insert streaming semantics.

## 4. Architecture

Gem `activerecord-clickhouse-adapter`, adapter name `"clickhouse"`, class
`ActiveRecord::ConnectionAdapters::ClickHouseAdapter`, internals namespaced
`ActiveRecord::ConnectionAdapters::ClickHouse::*` — the same layout Rails uses for
PostgreSQL (`postgresql_adapter.rb` + `postgresql/*.rb`).

```
lib/
  activerecord-clickhouse-adapter.rb            # registration only (lazy require)
  active_record/connection_adapters/
    clickhouse_adapter.rb                       # ClickHouseAdapter < AbstractAdapter
    clickhouse/
      http_connection.rb                        # persistent Net::HTTP, auth, params, errors
      format/json_compact.rb                    # read codec v1 (correctness baseline)
      format/row_binary.rb                      # read/write codec v2 (performance)
      type_parser.rb                            # recursive CH type-string parser (AST, not regex)
      types.rb + type/*.rb                      # ActiveModel::Type subclasses per CH family
      quoting.rb                                # literal quoting + server-side param binds
      database_statements.rb                    # perform_query / cast_result / affected_rows
      schema_statements.rb                      # tables/columns/indexes via system tables
      schema_creation.rb                        # DDL visitor (ENGINE/ORDER BY/PARTITION BY/TTL)
      table_definition.rb                       # migration DSL (engines, codecs, materialized cols)
      schema_dumper.rb                          # schema.rb with CH options (+ SHOW CREATE fidelity)
      column.rb / type_metadata.rb
      arel/visitor.rb                           # ToSql subclass: FINAL, SAMPLE, PREWHERE, SETTINGS, LIMIT BY
      relation_extensions.rb                    # Model.final / .settings / .prewhere / .sample
      explain.rb                                # EXPLAIN PLAN/PIPELINE/ESTIMATE/indexes=1
      database_tasks.rb                         # db:create/drop/schema for DatabaseTasks.register_task
      railtie.rb                                # rake task wiring when inside Rails
```

**Query pipeline** (the Rails 8.1 contract, already proven by the walking skeleton):
`select_value → select_all → internal_exec_query → raw_execute → log → with_raw_connection →
perform_query(conn, sql, …)` — we implement only the three leaf hooks
(`perform_query`, `cast_result`, `affected_rows`) plus `write_query?`, and the connection
lifecycle (`connect`, `reconnect`, `active?`, `disconnect!`). Everything else — query cache,
retries, reconnect-and-retry, async queries, instrumentation timing — comes from Rails for free
because we sit in the official pipeline.

**Pipeline drift, 8.1 → main (audited 2026-07-12):** Rails `main` replaced
`raw_execute`/`internal_exec_query` with a `QueryIntent` object — `perform_query(raw_connection,
intent)` (2-arg), results consumed via `intent.cast_result` / `intent.affected_rows`, and
`exec_insert/exec_update/exec_delete` are deprecated. Same three leaf hooks, different
signatures. The `RAILS_SOURCE=edge` job exists precisely to catch this; when 8.2 nears release
we add an arity-dispatched shim in `DatabaseStatements` rather than forking the adapter.

## 5. Design decisions ledger

1. **Binds = server-side query parameters.** Arel collects binds; our visitor emits
   `{p0:UInt64}` placeholders typed from the bind's `ActiveModel::Type`; the HTTP layer sends
   `param_p0=...`. True injection-proof binds (verified live), no client-side interpolation.
   Fallback to quoted literals only where a type can't be inferred.
   The `?`→`{pN:Type}` rewrite scans literal-aware (skips `'...'` strings and backtick
   identifiers — naive gsub corrupted `concat('what?', ?)`); integer param types are sized
   by magnitude up to Int256/UInt256 (a too-small type made the server wrap `2**70` → 0),
   beyond which we raise rather than wrap.
2. **Read path formats.** Default wire is `RowBinaryWithNamesAndTypes` (adopted
   Iteration 16 after benchmarks proved it — ledger #37); the JSON wire
   (`JSONCompactEachRowWithNamesAndTypes`, sent with
   `output_format_json_quote_decimals=1` + `output_format_json_quote_denormals=1` so
   Decimals stay exact and `NaN`/`±Inf` survive) remains as the per-query fallback for
   types without a binary decoder and as the `select_format: :json` escape hatch.
3. **Type parsing is an AST parser, not regexes.** `LowCardinality(Nullable(String))`,
   `Map(String, Array(Tuple(UInt8, Decimal(38, 10))))`, `DateTime64(3, 'UTC')`,
   `Enum8('a' = 1)` all parse into type nodes that build the caster chain. The prior art's
   regex approach is a documented failure mode.
4. **Transactions are honest no-ops.** `AbstractAdapter`'s own defaults for
   `begin/commit/rollback_db_transaction` are already empty bodies — we keep them, which means
   no `BEGIN` ever reaches the server (the prior art inherits `supports_transactions? → true`
   and risks emitting them). A strict mode (`raise_on_transaction: true` config) raises for
   apps that must not pretend.
   **Capability matrix is explicit, not inherited:** every one of the ~40 `supports_*`
   predicates gets a deliberate value with a comment; notable trues: `supports_explain?`,
   `supports_views?`, `supports_materialized_views?`, `supports_datetime_with_precision?`,
   `supports_json?`, `supports_comments?`, `supports_virtual_columns?` (MATERIALIZED/ALIAS),
   `supports_common_table_expressions?`, `supports_insert_on_duplicate_skip?` (true —
   vacuously: no unique constraints means nothing can conflict, see ledger #39),
   `supports_concurrent_connections?`.
5. **Mutations.** `delete` / `delete_all` → lightweight `DELETE FROM` (verified on 25.8);
   `update` / `update_all` → `ALTER TABLE ... UPDATE` mutation by default, automatic
   lightweight `UPDATE` when the server/table supports it. `mutations_sync` exposed as an
   adapter setting so specs are deterministic. Errors always raise — never silent.
6. **Primary keys.** No autoincrement in ClickHouse. Default `id: false`; opt-in
   `id: :uuid` (server `generateUUIDv4()`) or client-generated UUIDv7 via an
   `attribute` default. `ORDER BY` is the real "primary key"; the DSL makes it mandatory
   for MergeTree tables.
7. **Internal metadata tables.** `schema_migrations` and `ar_internal_metadata` as
   `ReplacingMergeTree(ver)` with `FINAL`-reading accessors — append-only-safe versions of
   Rails' bookkeeping (delete of a migration version inserts a tombstone, exactly as the
   ecosystem does it).
8. **Schema dumping.** `schema.rb` via our dumper (`create_table ... options:` string with
   full ENGINE clause, like the MySQL adapter does) for diffability, `structure.sql` via
   `SHOW CREATE TABLE` for byte-exact fidelity. Both tested round-trip: dump → load →
   `SHOW CREATE` equality.
9. **Errors.** Map `X-ClickHouse-Exception-Code` to a real taxonomy:
   60/81 → `StatementInvalid` subtypes (`UnknownTable`, `UnknownDatabase`), 241 →
   memory-limit, 159/160 → timeout, 516 → auth, connection refused → `ConnectionNotEstablished`.
   The full code list lives in `../clickhouse/src/Common/ErrorCodes.cpp`.
   **Mid-stream failure gotcha** (bit the prior art): once ClickHouse starts streaming a
   response it has already committed HTTP 200, and an error surfaces only as a
   `DB::Exception` fragment inside the body. v1 sends `wait_end_of_query=1` on selects
   (server buffers, status codes stay honest); the Phase 7 streaming codec takes over
   mid-stream exception detection explicitly, with specs that force such a failure.
10. **Timezones.** Server returns wall-clock strings in the column's timezone;
    `DateTime64(n, 'TZ')` metadata drives casting into `Time` with correct zone, specs pin
    both UTC and non-UTC server timezones.
11. **Settings passthrough.** Per-query `SETTINGS` via relation extension
    (`.settings(max_execution_time: 30)`), per-connection settings from `database.yml`
    (sent as HTTP params), never a shared session (stateless HTTP keeps pooling trivial).
12. **Coexistence.** Adapter name `"clickhouse"` collides with the PNixx gem by design —
    it is a drop-in replacement; both cannot be loaded at once. Migration guide ships in
    the README.
13. **Record-level mutations require an explicit primary key** *(reviewed 2026-07-12)*.
    `record.update/save/destroy` work when the model declares `self.primary_key`
    (the ReplacingMergeTree pattern where the sorting key is unique by design); models
    without one stay read-mostly — `update_all`/`delete_all` with explicit WHERE are the
    API. No synthetic ids, no silent no-ops.
14. **Compat-suite schema translation** *(reviewed 2026-07-12)*: vendored upstream suites
    that need implicit-id tables get a synthesized `order: "id"` in the harness's schema
    slice only — never in the adapter itself.
15. **Compat-suite fixtures** *(reviewed 2026-07-12)*: truncate-between-tests in the
    harness shim (no transactional rollback exists to lean on), mirroring the incumbent
    gem's consumer-facing test-helper hooks.
16. **`join_use_nulls=1` by default** *(Iteration 8)*: ClickHouse's native default fills
    unmatched outer-join columns with type defaults (0, ''), which silently corrupts
    Rails aggregate/pluck semantics. The adapter sends `join_use_nulls=1` on every
    request for SQL-standard NULLs; `join_use_nulls: 0` in `database.yml` opts back out.
17. **Fixture loading bypasses transactions** *(Iteration 8)*: `insert_fixtures_set`
    is overridden to TRUNCATE the target tables and replay each table as one batched
    INSERT — Rails' default path wraps bare `DELETE FROM` in a transaction, and neither
    exists here.
18. **Adapter returns plain `Time`** *(Iteration 8)*: the DateTime caster yields `Time`
    instances (UTC instants), matching every built-in adapter's database layer;
    `TimeWithZone` wrapping stays in the attribute layer where Rails puts it.
19. **Client-side primary key prefetch** *(Iteration 9, approved by Ikraam)*: the adapter
    generates ids before INSERT via Rails' Oracle-era seam (`prefetch_primary_key?` /
    `next_sequence_value`), but only when the table's sorting key is a single column
    typed ≥64-bit integer (time-ordered 63-bit id: 41 bits of Unix ms + 22 random bits)
    or UUID (UUIDv7). Composite/expression/narrow/string keys never prefetch — those
    models assign ids explicitly, and a mismatched model pk raises with guidance rather
    than silently inserting a zero. `#insert` surfaces the prefetched id as the
    RETURNING row because ClickHouse has no `INSERT ... RETURNING`.
20. **`high_precision_current_timestamp` is `now()`** *(Iteration 9)*: Rails stamps both
    date (`*_on`) and datetime (`*_at`) attributes with this single expression in
    `insert_all`, and only a plain DateTime coerces into both Date32 and DateTime64
    VALUES targets — so bulk-insert timestamps carry second precision.
21. **Sorting-key lookup is cached per connection** *(Iteration 10, approved by Ikraam)*:
    Rails calls `prefetch_primary_key?` on every create, which cost one `system.tables`
    join per INSERT. `generatable_primary_key` memoizes per table (nil results included)
    and the migration-API DDL methods (`create_table`/`drop_table`/`rename_table`) clear
    the whole cache. DDL issued through raw `execute` bypasses invalidation — accepted:
    schema changes outside the migration API already require `reset_column_information`.
22. **nil binds are `Nullable(Nothing)`** *(Iteration 10)*: the one param type that both
    carries NULL (`\N`) and compares against any column type. Typing nil binds by their
    AR column type corrupts silently — an empty `Nullable(String)` param is `''`, not
    NULL — and non-Nullable param types reject the value outright.
23. **`quoted_date` always encodes UTC** *(Iteration 11)*: DateTime64 stores an epoch and
    the server parses naive strings in its own timezone (UTC), while params reject
    offsets outright — so UTC is the only faithful wire encoding. The abstract
    implementation emits local wall-clock under `default_timezone = :local`, silently
    shifting every stored instant; the override makes `:local` round-trip correctly.
24. **Mutation affected-rows are counted client-side** *(Iteration 11)*: the server
    reports nothing, so `update`/`delete` run `SELECT count()` with the mutation's WHERE
    just before mutating. One extra cheap query per (already heavyweight) mutation buys
    Rails semantics: `update_all`/`delete_all` return counts, `update_columns` returns
    a real boolean, and optimistic locking raises `StaleObjectError` honestly. Rows
    touched by concurrent writes between count and mutation are not reflected; raw-SQL
    mutations and LIMIT/ORDER statements fall back to 0.
25. **No RETURNING means the prefetched pk is the only returning value** *(Iteration 11)*:
    `return_value_after_insert?` is false for every column (default expressions are
    server-side and unknowable), and `insert` aligns its returning row to the requested
    columns so the generated id lands on the pk attribute — previously the first
    default-function column silently swallowed it.

26. **OLAP totals ride ROLLUP, not WITH TOTALS** *(Iteration 12)*: the totals row is
    emitted out-of-band (a separate `totals` field in framed JSON formats) and our
    row-stream wire format drops it entirely, so `.rollup` delivers totals as ordinary
    rows instead — keyed `nil` via `group_by_use_nulls=1` (except LowCardinality group
    columns, which keep their type default; documented in the spec).

27. **Materialized views require a TO target** *(Iteration 12)*: inner-storage views hide
    data in an implicit `.inner` table and `POPULATE` misses rows inserted during the
    backfill, so `create_materialized_view` refuses both. The dumper reads
    `system.tables.as_select` + the `TO` clause of `create_table_query`, strips the
    current-database qualifiers, and emits views after all tables.

28. **Async inserts are connection config with a durable default** *(Iteration 12)*:
    `async_insert: true` in the database config turns on server-side insert batching for
    every statement on that connection; `wait_for_async_insert` stays 1 unless explicitly
    set to 0, because a fire-and-forget ack can lose rows on a server crash.

29. **Aggregate calculations carry merge: and if:, not new method names** *(Iteration 13)*:
    `-Merge` (finishing AggregateFunction state columns) and `-If` (conditional
    aggregation in one scan) are options on the existing `uniq_count`/`quantile`/
    `top_k`/`arg_max`/`arg_min`, keeping one surface instead of a combinator matrix.
    `merge: true` with `if:` is refused loudly (no `-MergeIf` combinator exists).
    Grouped relations return Rails-shaped hashes (scalar key for one group column,
    array for several) so merged reads compose with `group`/`group_by_period`.

30. **Relation settings apply to writes as per-request HTTP parameters** *(Iteration 14)*:
    SELECTs carry `.settings` in-SQL, but ALTER/INSERT grammars each place SETTINGS
    differently, so `insert_all`/`update_all`/`delete_all` scope the same relation
    state through `with_request_settings` (connection-level, restored after the block).
    Setting names are validated before they reach the wire.

31. **ClickHouse column/table storage clauses are first-class DSL options** *(Iteration 14)*:
    `codec:`, `materialized:`, `alias:` on columns (mutually exclusive with `default:`,
    enforced client-side) and `primary_key:`/`sample:` on tables — all introspected from
    `system.columns`/`system.tables` and dumped round-trip. Under `id: false` the Rails
    `primary_key:` kwarg is inert, so the DSL reuses it for the PRIMARY KEY clause.

32. **Partition verbs use the PARTITION ID literal form only** *(Iteration 14)*:
    `partitions`/`detach_partition`/`attach_partition`/`drop_partition`/
    `freeze_partition` quote the partition id as a plain literal, so arbitrary
    expressions never reach the ALTER — the OLAP replacement for bulk deletes/archival.

33. **Savepoint verbs are honest no-ops, like the transaction verbs** *(Iteration 15)*:
    Rails opens savepoints for `requires_new: true` nested inside a dirty transaction
    regardless of `supports_savepoints?` (§2), so `create_savepoint`/
    `exec_rollback_to_savepoint`/`release_savepoint` are empty bodies — the alternative
    is a server syntax error inside every `create_or_find_by` retry. Nothing pretends
    to roll back: nested `ActiveRecord::Rollback` leaves the write in place (specced).

34. **Result columns strip the analyzer's join qualifiers when unambiguous**
    *(Iteration 15)*: multi-join qualified stars come back as `table.column` (§2), which
    would break Rails' by-name attribute mapping (`MissingAttributeError` on every
    multi-join `t.*` read). `cast_result` strips the qualifier wherever the bare name
    stays unique in the result; genuine duplicates keep the server's qualified names.

35. **Identifier matchers admit backtick-quoted names** *(Iteration 15)*:
    `column_name_matcher`/`column_name_with_order_matcher` mirror MySQL's, because
    `disallow_raw_sql!` vets `order`/`pluck` arguments against them and the abstract
    versions reject this adapter's own `quote_column_name` output.

36. **Mutation counts follow Rails' ORDER/LIMIT rewrite** *(Iteration 16)*: the
    pre-mutation `SELECT count()` (decision #24) rebuilds the same
    `WHERE pk IN (SELECT ... LIMIT n)` shape Rails compiles ordered/limited
    mutations into — a capped count via subquery — instead of returning 0; and the
    Arel visitor stops de-qualifying column names once it descends into a nested
    SELECT, because those subqueries carry JOINs whose ON clauses need qualifiers.

37. **RowBinary is the default read wire, JSON the per-query fallback** *(Iteration 16)*:
    `RowBinaryWithNamesAndTypes` decodes straight to final Ruby values (2x faster,
    2.5x fewer allocations on the 10k-row baseline — BASELINE.md), and both wires
    still flow through the same `Types` casters, which are idempotent on decoded
    values. A type without a binary decoder (AggregateFunction states, exotics)
    raises `RowBinary::Undecodable` and the connection re-runs that query on the
    JSON wire — SELECTs are safe to retry, and mutations return no columns so they
    never trigger it. `select_format: :json` in the config forces JSON everywhere.

38. **insert_stream is the materialization-free bulk path** *(Iteration 16)*:
    `connection.insert_stream(table, rows)` (and the model-level sugar on the
    Querying concern) streams any Enumerable of hashes as one chunked
    `JSONCompactEachRow` POST — no SQL string rendering, one HTTP chunk of the
    batch in memory at a time, 4.8x faster than `insert_all!` on the 1k-row
    baseline. Times/dates/decimals encode via `quoted_date`/`to_s("F")`; the
    server casts everything else from JSON.

39. **insert_all's duplicate-skip is vacuously satisfied** *(Iteration 17)*: Iteration 4
    made `insert_all` raise (`supports_insert_on_duplicate_skip? = false`) to avoid
    prior art's lie of claiming conflict handling that doesn't exist. Porting TRMNL core
    showed the raise punishes the common OLAP write path: its telemetry sink writes
    exclusively through `insert_all`. Reversed: with no unique constraints nothing can
    conflict, so skip-duplicates holds vacuously and a plain INSERT is emitted.
    `upsert_all` (update semantics) still raises with a pointer at
    Replacing/SummingMergeTree engines.

40. **Trailing sqlcommenter comments are hoisted on INSERT** *(Iteration 17)*: Rails
    QueryLogs appends `/*tags*/` after the statement; ClickHouse parses everything after
    `VALUES` with the Values input format and rejects a trailing comment (code 27).
    `perform_query` moves a comment-shaped tail to the front of INSERT statements only —
    SELECTs keep theirs, string literals that merely contain `/*` are untouched (the
    regex must match from a real `/*` to end-of-string).

41. **The gemspec never touches the runtime namespace** *(Iteration 17)*: the version is
    a literal in the gemspec, asserted in sync with `ClickHouse::VERSION` by spec.
    Bundler evaluates gemspecs of path/git-sourced gems before Rails loads; defining
    `ActiveRecord::ConnectionAdapters::ClickHouse::VERSION` that early created the
    `ActiveRecord` module ahead of active_record.rb and silently disabled its autoloads.

42. **DateTime reads follow `default_timezone` for representation only** *(Iteration 18)*:
    DateTime64 stores an epoch, so the instant is zone-free; under
    `ActiveRecord.default_timezone = :local` both wire paths now hand back local-zoned
    Time instances (`Time.at` local / `getlocal`) instead of UTC-zoned ones, matching
    every built-in adapter. Writes are untouched — `quoted_date` still always encodes
    UTC (ledger #23), so the stored instant never shifts.

43. **Window sugar rides Arel's own Window/Over nodes** *(Iteration 19)*: `.window`
    appends one projected `fn(args) OVER (PARTITION BY … ORDER BY … [frame])` per call
    via `select_values` — no custom nodes, no visitor changes, because `to_sql` already
    renders `Arel::Nodes::Window`. The function name and alias must match an identifier
    regex and the frame must start with ROWS/RANGE/GROUPS; those are the only free-form
    strings (columns go through `arel_table`, so they quote themselves). ClickHouse 25.8
    supports `lag`/`lead` directly — no `lagInFrame` fallback needed (probed live).

44. **create_dictionary infers columns and injects credentials** *(Iteration 20)*: the
    dictionary DDL reads the source table's columns (`name sql_type` verbatim) instead
    of asking for a second schema block, and always writes USER/PASSWORD into
    SOURCE(CLICKHOUSE(…)) because the dictionary loader authenticates separately —
    without them every dictGet dies with AUTHENTICATION_FAILED (grounding fact). Layout
    and lifetime stay thin (`layout: :hashed`, `lifetime: 0..300`); `.dict_get` projects
    dictGet/dictGetOrDefault through `select_values` with names as quoted literals, so
    only the alias needs identifier validation.

45. **`cluster:` config stamps DDL, nothing else** *(Iteration 20)*: one adapter-level
    `on_cluster_clause` renders `ON CLUSTER` into CREATE/ALTER TABLE (SchemaCreation
    visitors), DROP (drop_table_sql), RENAME, remove_column and MODIFY COLUMN — DML and
    queries never see it. Chosen over the incumbent's per-migration `cluster` DSL noise:
    the cluster is deployment topology, so it belongs in database.yml, and single-node
    development ignores it entirely.

46. **Projections dump as `add_projection` lines parsed from `system.projections`**
    *(Iteration 20)*: the stored query text (`SELECT … [GROUP BY …] [ORDER BY …]`) is
    split by regex back into the same `select:/group:/order:` kwargs `add_projection`
    takes, appended right after each table's `create_table` block — the dump loads and
    re-dumps byte-identically without a structure.sql detour.

47. **The alter surface is MODIFY COLUMN all the way down** *(Iteration 21)*:
    `change_column` renders the full new definition (type wrappers + DEFAULT in one
    statement), `change_column_null` re-reads the current sql_type and toggles the
    Nullable wrapper, and the Rails backfill default runs first as a synchronous
    mutation (`mutations_sync = 1`) because narrowing over stored NULLs is a server
    error, not a silent coercion. `add_index`/`remove_index` reuse the CREATE-time
    data-skipping grammar via ALTER. All verbs carry `on_cluster_clause`.

48. **Dictionaries round-trip both dump formats without leaking credentials**
    *(Iteration 21)*: schema.rb emits `create_dictionary` identity kwargs only
    (columns re-infer, credentials re-inject at load); structure.sql keeps the
    server's own `PASSWORD '[HIDDEN]'` masking and `structure_load` swaps the
    loading connection's USER/PASSWORD back into CREATE DICTIONARY statements —
    the file stays portable across environments and secret-free.

49. **Dictionaries are not BASE TABLEs** *(Iteration 21)*: `data_source_sql`
    excludes engine = 'Dictionary' from the "BASE TABLE" type so `tables` (and the
    dumper's create_table loop) skip them; they remain in `data_sources` so
    structure.sql still carries them. The dumper also finally honors
    `ignore_tables` for materialized views and dictionaries.

50. **`perform_query` speaks both adapter contracts** *(Iteration 22)*: Rails main
    (8.2.0.alpha) replaced the positional
    `perform_query(conn, sql, binds, casted, prepare:, notification_payload:, batch:)`
    with `perform_query(conn, intent)` carrying a `QueryIntent`. The adapter defines
    whichever signature matches at load time (guarded on
    `ConnectionAdapters.const_defined?(:QueryIntent)`) and both delegate to one
    `execute_wire_query` body — no monkeypatch, no runtime branching per query.
    `explain` switched from the removed-on-main `internal_exec_query` to
    `select_all`, which both versions provide. Upstream drift in the *vendored 8.1.3
    test text* (not adapter behavior) lives in `skips_edge.yml`, merged into the
    manifest only when `ActiveRecord.gem_version >= 8.2.0.alpha`.

51. **CI truths the local environment can't see** *(Iteration 22)*: RuboCop's
    `AllCops: Exclude` replaces the default exclusions unless `inherit_mode`
    merges them — in CI, where bundler installs into `vendor/bundle` inside the
    workspace, that meant scanning installed gems' own rubocop configs. And
    `Hash#inspect` renders `{key => value}` before Ruby 3.4, so the schema
    dumper formats the `settings:` option itself instead of trusting `inspect`.

52. **Rails' index option surface is accepted verbatim; only using:/granularity:
    matter** *(Iteration 23)*: `add_index` asserts the abstract adapter's
    `valid_index_options` plus `:granularity` (and the `internal:` flag), so
    cross-database migrations port without edits — `length:`, `where:`,
    `order:` etc. are accepted and ignored, the same posture MySQL takes toward
    Postgres-only options. `unique:` is accepted but unenforceable (no unique
    indexes in ClickHouse), so `index_exists?(unique: true)` honestly reports
    false. `remove_index` delegates to Rails' `index_name_for_remove`, which
    matches by columns rather than derived name — custom-named indexes resolve
    by their columns, and a name-shaped column string is refused, byte-for-byte
    upstream semantics.

53. **DSL datetimes default to microsecond precision like Rails, not
    millisecond like ClickHouse** *(Iteration 23)*: the adapter now claims
    `supports_datetime_with_precision?`, so `t.datetime` without an explicit
    `precision:` gets Rails' convention of 6 (`DateTime64(6, 'UTC')`) instead
    of the previous CH-idiomatic 3. Explicit `precision:` always wins; existing
    columns are untouched. Chosen for AR parity: timestamp round-trips through
    Time objects preserve microseconds by default on every other adapter.

54. **Harness translation rule: bare `DELETE FROM t` gets `WHERE 1`**
    *(Iteration 27)*: upstream test code cleans join tables with portable-SQL
    `DELETE FROM t` strings, which ClickHouse's lightweight DELETE rejects
    (WHERE is mandatory). The adapter itself still passes raw SQL through
    untouched — the rewrite lives in the harness helper (same family as the
    inline-DDL rule, #14), pinning the portable form to exactly what the Arel
    visitor emits for unscoped relation deletes. Replaced two manifest skips
    with passing tests. *(Iteration 28)*: the hook moved from
    execute/exec_delete to the adapter's own `execute_wire_query` — Rails main
    routes `connection.delete(sql)` through `QueryIntent#execute!`, which skips
    both public methods, but every version still funnels through the wire
    method we implement.

55. **Decimal DDL: bare precision means scale 0; bare scale raises**
    *(Iteration 28)*: `t.decimal :n, precision: 2` previously rendered
    `Decimal(2, 10)` from the independent 38/10 fallbacks, which ClickHouse
    rejects (ARGUMENT_OUT_OF_BOUND: scale may not exceed precision). Now
    precision-only follows the SQL convention of scale 0, scale-only raises
    the same ArgumentError as Rails' bundled adapters, and only the fully
    unbounded column keeps the wide `Decimal(38, 10)` default. `:binary` and
    `:blob` also map to `String` now — ClickHouse strings are arbitrary byte
    sequences, so this is the honest widest mapping.

56. **Empty inserts render as `FORMAT JSONEachRow {}`** *(Iteration 29)*: Rails
    turns an attribute-less create into `INSERT INTO t DEFAULT VALUES`, which
    ClickHouse doesn't parse and which has no direct equivalent (`VALUES ()`
    is a syntax error, `(col) VALUES (DEFAULT)` needs a column name the seam
    doesn't always have). An empty JSONEachRow row inserts exactly one row
    with every column at its table default, so `empty_insert_statement_value`
    returns that — probed live, works with and without a primary key.

57. **Manifest skips fire after class setup, not before** *(Iteration 30)*:
    Minitest runs teardown even for skipped tests, and vendored teardowns
    restore process-global config from ivars their setup captured
    (`SerializedAttributeTestWithYamlSafeLoad` writes
    `ActiveRecord.yaml_column_permitted_classes` back from
    `@yaml_column_permitted_classes_default`). The harness's skip hook used to
    run *before* setup, so a skipped test's teardown nil'd the global and
    poisoned every later YAML-serialization test in the process. The hook now
    lives in `after_setup`, matching upstream's inline-skip semantics exactly.

58. **Mutations refuse key columns — visible under partial_writes off**
    *(Iteration 31)*: `ALTER TABLE … UPDATE` cannot SET a sorting-key column
    (CANNOT_UPDATE_COLUMN, code 420, probed live). Normal Rails updates never
    touch the pk, but `partial_writes = false` makes every UPDATE write all
    columns including `id`, so those upstream tests skip with the
    `key_column_update` seam rather than the adapter special-casing the
    column list.

59. **Skip overlays can retire whole vendored classes** *(Iteration 32)*: Rails
    main froze `attribute_method_patterns` (ractor safety), and the pinned
    8.1.3 `attribute_methods_test.rb` teardown mutates it in place
    (clear/concat) — erroring all 117 tests in the class before any per-test
    skip can help, because Minitest runs teardown even for skipped tests. A
    suite-level `"*"` entry in an overlay now empties the class's
    `runnable_methods`, retiring it on that Rails version only. The mechanism
    is overlay-agnostic but should stay a last resort: per-test skips keep the
    rest of a class honest.

60. **The harness owns its own database** *(Iteration 32)*: the embedded
    harness subprocess and the parent rspec suite used to share
    `ar_clickhouse_test`, and the TRMNL corpus spec drops/recreates five table
    names the schema slice also owns (events/logs/jobs/requests/deploys). The
    full-gate storm (four sightings, never reproducible standalone) stopped
    being worth diagnosing per-seed: the harness now bootstraps and connects to
    `ar_clickhouse_compat` (override: `CLICKHOUSE_COMPAT_DATABASE`), killing
    the shared-namespace hazard outright.

61. **Explicit `precision: nil` means plain DateTime** *(Iteration 33)*: Rails
    injects precision 6 for a bare `t.datetime` (new_column_definition checks
    `options.key?(:precision)`), so a nil that reaches `type_to_sql` was
    explicit — it now maps to second-precision `DateTime('UTC')`, mirroring
    MySQL's plain `datetime`. Precision past 9 (DateTime64's nanosecond cap,
    ARGUMENT_OUT_OF_BOUND code 69 live) raises Rails' own ArgumentError wording
    at DDL-build time. `change_column` gained the same key-presence defaulting,
    and the dumper's always-dump-precision override is gone: the adapter default
    is 6, so upstream's omit-6 / `precision: nil` conventions apply verbatim.

62. **Failover retries connect-phase failures only** *(Iteration 45)*: `hosts:`
    lists interchangeable replicas ("host" or "host:port", `port:` the default).
    `HTTPConnection` keeps one endpoint list; a request that dies on
    ECONNREFUSED / EHOSTUNREACH / SocketError / Net::OpenTimeout provably never
    reached a server, so it rotates to the next endpoint and retries (at most
    one attempt per endpoint). Mid-flight failures (Net::ReadTimeout, resets)
    raise — the statement may have executed, and replaying could double a
    write. A process-wide ledger round-robins starting endpoints across
    connections and skips endpoints that refused within `failover_cooldown:`
    seconds (default 30). No health-check pings, no background threads.

63. **`read_only: true` is server-enforced via `readonly=2`** *(Iteration 45)*:
    the option stamps `readonly=2` on every request — 2, not 1, because strict
    readonly refuses the adapter's own session settings (join_use_nulls et al.)
    with code 164 before any query runs. Code 164 translates to
    `ActiveRecord::ReadOnlyError` (the class `while_preventing_writes` raises),
    so server-configured readonly users surface identically. Grant refusals
    (code 497) get their own `ClickHouse::AccessDenied < StatementInvalid`;
    note grants are checked before readonly, so a SELECT-only user's DDL raises
    AccessDenied, not ReadOnlyError.

64. **`primary_keys` reports a single-column id-typed sorting key**
    *(Iteration 46, approved by Ikraam — revises the Phase 3 blanket `[]`)*:
    both contracts, honestly split. Rails' contract: `connection.primary_keys`
    drives model pk auto-detection, so an id-keyed table now behaves drop-in
    (`find`/`update`/`destroy`/prefetched ids) with no `self.primary_key`
    boilerplate. ClickHouse's contract: PRIMARY KEY is an index prefix, not a
    uniqueness guarantee, so reporting is limited to the one shape the adapter
    already treats as identity — a sorting key that is exactly one U/Int64+ or
    UUID column, the same gate as the client-side id generator (`generatable_
    primary_key`, one cached lookup serves both). Composite, expression, and
    non-id-typed sorting keys still report `[]`; explicit `self.primary_key`
    remains the seam for those (decision #13, e.g. ReplacingMergeTree slugs).
    The schema dumper suppresses reporting during dumps
    (`with_suppressed_primary_key_reporting`): Rails' dumper would fold a
    reported pk into `create_table`'s implied id column, which degrades
    UInt64 → Int64 on reload; every table keeps dumping as `id: false` +
    explicit columns + `order:`. The DSL side: `create_table id: :bigint/:uuid`
    now works without an `order:` — the pk column is its own obvious sorting
    key (native type `:primary_key` → plain Int64; no autoincrement exists, ids
    are client-generated). Erased four harness skips (PrimaryKeysTest
    auto-detect/prefix/returns-value, PrimaryKeyWithAutoIncrementTest bigint);
    composite reporting stays out — Rails supports composite pks, but a
    ClickHouse composite sorting key is an index prefix over non-unique rows,
    and claiming identity there invites silent multi-row mutations.

## 6. Phased roadmap (each phase lands green + benchmarked before the next)

**Phase 0 — Foundations** *(done)*
Walking skeleton: registration, HTTP connection, query pipeline hooks, live
`select_value("SELECT 1") == 1`, `active?`, `database_version`. 4 specs green, rubocop clean.

**Phase 1 — Type system (read path).** *(done — Iteration 1)*
`TypeParser` recursive-descent AST + `Types` caster registry + eager `cast_result`.
Scalars (U/Int 8–256, Float, Decimal(P,S), String/FixedString, Date/Date32,
DateTime/DateTime64+TZ, Enum8/16, UUID, Bool, IPv4/6, Nullable, LowCardinality),
composites (Array, Map, positional/named Tuple, JSON), SimpleAggregateFunction→inner,
AggregateFunction opaque. Coverage ratchet against `system.data_type_families`.
58 examples green. Deferred: Nested, geometry, Interval*, Time/Time64, Dynamic/Variant,
NaN/Inf quoting. Port targets remain available for deepening edge coverage later.

**Phase 2 — Quoting, binds, errors.** *(done — Iteration 2)*
`Quoting` (CH string escapes, backticks, array/map literals), server-side `{pN:Type}`
binds via the Arel Bind collector (`default_prepared_statements = true` only selects that
path — nothing is prepared on the server), error taxonomy for codes 60/81/241/159/160/516,
`wait_end_of_query=1` on HTTP selects. 72 examples green.

**Phase 3 — Schema statements + migrations.** *(core done — Iteration 3)*
Landed: `tables`/`views`/`columns`/`indexes`/`primary_keys` via `system.tables`/
`system.columns`/`system.data_skipping_indices` (no `SHOW CREATE` string parsing); migration
DSL `create_table engine:, order:, partition:, ttl:, settings:` with `id: false` default,
mandatory ORDER BY for MergeTree, `null:`/`low_cardinality:` type wrapping, sized integer
limits, proc defaults; `Arel::Visitors::ClickHouse` (official visitor seam) unqualifying
DELETE WHERE columns; internal metadata tables as ReplacingMergeTree via a `create_table`
name intercept (no prepends onto `SchemaMigration`/`InternalMetadata`); full
`MigrationContext` flow green (migrate/re-migrate/rollback); **TRMNL core's 16 real
migrations run verbatim up and down** (`spec/clickhouse/trmnl_corpus_spec.rb`); e2e spine
started (`spec/integration/end_to_end_spec.rb`). 122 examples green.
Deferred: column `codec:`/`materialized:`/`alias:`, skip-index DSL (raw `INDEX` in execute
works), materialized views, `db:*` rake tasks via `DatabaseTasks.register_task`,
schema dumper (Phase 3.5/8), Rails `migration/*` port targets.

**Phase 4 — CRUD + relation semantics.** *(core done — Iteration 4)*
Landed: `insert_all!` batched INSERT (VALUES with server-side binds); `insert_all`/
`upsert_all` raise honestly (`supports_insert_on_duplicate_* = false`); `delete_all` →
lightweight DELETE with `WHERE 1` injected when unscoped; `update_all` → `ALTER TABLE ...
UPDATE` mutation via the Arel visitor; `mutations_sync` adapter config (HTTP param);
relation coverage (exists?/find_by/distinct/or/not/limit/offset/multi-pluck/Decimal
calculations); `find_each(cursor:)` batches without id; lightweight-delete oracle port
from `02319_lightweight_delete_on_merge_tree.sql`. 146 examples green.
Deferred: full Rails `insert_all_test`/`calculations_test` ports into the Phase 6 compat
harness with `skips.yml`; `update`/`save` on loaded records (needs pk semantics decision);
async insert settings (Phase 8).

**Phase 5 — The ClickHouse dialect (Arel + relation extensions).** *(core done — Iteration 5)*
Landed: `Relation#final/#sample/#prewhere/#settings/#limit_by` via an opt-in model concern
(`include ClickHouse::Querying` → `default_scope { extending(RelationMethods) }` — public
seams only, zero monkeypatches); custom Arel nodes (TableWithModifiers, Prewhere,
DialectSuffix riding the unused lock slot) rendered by `Arel::Visitors::ClickHouse`;
`Relation#explain(:plan/:pipeline/:estimate/:indexes)` returning real server output via
`build_explain_clause`; SETTINGS name validation; LIMIT BY oracle port from
`00409_shard_limit_by.sql`. 167 examples green.
Deferred: `ARRAY JOIN`/`GLOBAL JOIN` modifiers, window-function passthrough specs,
`00409_prewhere` deep ports (basic prewhere proven live).

**Phase 6 — Rails-compat harness at scale.** *(harness landed — Iteration 6; review summit)*
Landed: `spec/rails_compat/` — vendored upstream suites byte-exact from the **v8.1.3 tag**
(`vendor/UPSTREAM` records provenance + refresh command), a minimal `cases/helper` shim
(connection config, `current_adapter?`, timezone helpers, skip-manifest setup hook),
`run.rb` minitest runner, `skips.yml` ratchet (currently **empty** — mechanism verified
live), and an RSpec wrapper so `bundle exec rspec` covers the harness. First corpus:
`quoting_test`, `type_test`, `errors_test` — 41 upstream runs, 0 failures, 0 skips.
Next expansions (post-review): suites needing schema/fixtures (`basics_test`,
`calculations_test`, `insert_all_test`) — these need a schema-translation rule
(implicit-id tables) and a fixture strategy; both are open design questions below.

**Phase 7 — Performance program.** *(core done — Iteration 7)*
Landed: `sql.active_record` payload gains `clickhouse: {query_id:, read_rows:, read_bytes:,
written_rows:, elapsed_ns:}` from `X-ClickHouse-Summary` (spec/clickhouse/
instrumentation_spec.rb + e2e spine assertions); HTTP gzip compression on by default
(`enable_http_compression=1`, `compression: false` opt-out, error bodies verified readable);
`benchmarks/round_trip.rb` (benchmark-ips + memory_profiler) with the committed baseline in
`benchmarks/BASELINE.md`; DateTimeCaster wire-format fast path (`zone.local` over
`zone.parse`) — 10k-row typed select went 5.3 → 13.2 i/s and 43.2 → 26.6 MB allocated.
Also landed this iteration: record-level `update/save/destroy` for models declaring
`self.primary_key` (decision #13). 181 examples green.
Deferred (benchmark-gated, per BASELINE.md): RowBinary codec — JSON.parse is now ~4 MB of
a 26.6 MB profile, not the bottleneck; zstd; streaming `read_body` decode; async inserts
(Phase 8); `system.query_log` cross-check helper.

**Phase 3.5 — Schema dumper + database tasks.** *(done — Iteration 8)*
Landed: `ClickHouse::SchemaDumper` (create_schema_dumper seam) dumping engine/partition/
order/ttl/settings from `system.tables.engine_full`, AR-native column types only when
`type_to_sql` regenerates the server type exactly (else verbatim ClickHouse type strings),
`low_cardinality:`/`null:` options, data-skipping indexes with `using:`/`granularity:`
(`supports_indexes_in_create?` + `index_in_create`); byte-identical re-dump proven for the
spec tables **and the TRMNL corpus**; `ClickHouseDatabaseTasks` registered via
`DatabaseTasks.register_task` (db:create/drop/purge honoring codes 82/81, structure
dump/load via `SHOW CREATE TABLE`); e2e spine gained the dump → load → re-query leg.

**Phase 6 (cont.) — calculations_test corpus.** *(landed — Iteration 8; review summit)*
`calculations_test` vendored byte-exact (22 models, 11 fixture sets, hand-translated
~27-table schema slice); fixtures load through a TRUNCATE-based `insert_fixtures_set`
override; helper shim grew fixtures/capture_sql/with_timezone_config/QUOTED_TYPE.
Unlocked along the way: String bind escaping, `join_use_nulls=1` default, plain-Time
DateTimeCaster, datetime precision 6 in the slice. **273 runs, 0 failures, 24 skips**
— every skip categorized in `skips.yml`: 5 functional-dependency GROUP BY, 1 self-join
ambiguity, 16 no-autoincrement (decision #14), 2 upstream-conditional.

**Phase 6 (cont.) — client-side primary keys + insert_all_test corpus.** *(landed — Iteration 9)*
Client-side pk prefetch (decision #19) erased all 16 no-autoincrement skips; `#insert`
surfaces the prefetched id as the RETURNING row; boolean literal defaults reclassified so
`auto_populated?` stays honest. `insert_all_test` vendored byte-exact (+4 models, +4
slice tables incl. a composite-sorting-key carts); helper shim grew upstream's
capability-predicate delegation (`supports_insert_returning?` et al.), so unsupported
upsert/conflict tests self-skip exactly as upstream intends;
`high_precision_current_timestamp` now stamps `record_timestamps` bulk inserts. Harness:
**362 runs, 0 failures, 83 skips** (9 manifest — 5 GROUP BY, 1 self-join, 3 no-unique-
constraint semantics; 74 capability self-skips). Suite: 227 examples green.

**Phase 6 (cont.) — nil binds, sorting-key cache + finder_test corpus.** *(landed — Iteration 10)*
Two adapter fixes fell out of the corpus: nil binds now travel as `Nullable(Nothing)`/`\N`
(they were silently becoming `''` for strings and erroring for integers), and
`rename_table` landed on plain `RENAME TABLE`. `generatable_primary_key` is cached
per connection (Rails checks `prefetch_primary_key?` on every create) and invalidated by
create/drop/rename_table. `finder_test` vendored byte-exact (+12 models, +9 fixture sets,
+18 slice tables); upstream's `raise_on_missing_required_finder_order_columns = true`
now set in the helper shim (mirrors test/support/global_config.rb); `PRIMARY_KEYS` slice
map supports explicit nil for id-column tables that must stay pk-less. The upstream
`comments.comments` column stays out of the slice (qualified-matcher quirk, §2). Harness:
**636 runs, 0 failures, 87 skips** (13 manifest — 6 GROUP BY, 2 self-join, 3 no-unique-
constraint, 2 default_timezone :local; 74 capability self-skips). Suite: 238 examples green.

**Phase 6 (cont.) — write-path semantics + persistence_test corpus.** *(landed — Iteration 11)*
Workaround sweep first: `quoted_date` now always encodes UTC (erased both
default_timezone :local skips — ledger #23); the legacy-analyzer probe showed self-join
and qualified-matcher fixes exist but only behind the deprecated analyzer, documented not
shipped. Then `persistence_test` vendored byte-exact (+12 models incl. `admin/`,
+3 fixture sets, +8 slice tables), which surfaced four real write-path gaps:
affected rows now counted client-side before each mutation (ledger #24 — makes
`update_all`/`delete_all` counts, `update_columns` booleans, and optimistic locking
honest), `return_value_after_insert?` false + returning aligned to the pk (ledger #25 —
a default-function column was silently swallowing the generated id),
`next_sequence_value` accepts free-form sequence labels (Oracle legacy, e.g. Rails'
`companies_nonstd_seq`) and raises clearly for composite pks, and
`change_column_default` landed on `MODIFY COLUMN ... DEFAULT`/`REMOVE DEFAULT`.
Harness: **801 runs, 0 failures, 91 skips** (17 manifest — 6 GROUP BY, 2 self-join,
3 no-unique-constraint, 3 no-autoincrement, 2 immutable-sorting-key, 1 correlated
subquery; 74 capability self-skips). Suite: 252 examples green.

**Phase 7 — OLAP-native surface.** *(landed — Iteration 12)*
Three tiers, all probed live first. Tier 1 relation sugar on the `extending` seam:
`group_by_period` (toStartOfInterval buckets, auto-ordered), `.fill(step:)` (WITH FILL on
the last ORDER BY expression), `.rollup` (in-band totals keyed nil — ledger #26),
`uniq_count`/`quantile`/`top_k`/`arg_max`/`arg_min` (parametric aggregates with
Float/Integer coercion as the injection guard), and `estimated_count` (O(1) from
`system.tables.total_rows`). Tier 2 DDL: `create_materialized_view`/`drop_materialized_view`
(TO target mandatory — ledger #27) with byte-identical schema.rb round-trip,
`add/drop/materialize_projection`, `optimize_table(final: true)`. Tier 3 ingestion:
`async_insert` connection config (durable by default — ledger #28); stock `find_each`
proven optimal by EXPLAIN and locked in by spec, no custom batching. Deferred:
-State/-Merge aggregate combinators (until a real consumer asks), projections in
schema.rb (structure.sql carries them). Suite: 300 examples green; harness unchanged.

**Phase 7 (cont.) — aggregate-state pipeline.** *(landed — Iteration 13)*
The deferral above lasted one iteration: the reference-corpus survey (ecto_ch,
clickhouse-sqlalchemy, infi) showed `-State`/`-Merge` is the pattern every good
ClickHouse ORM converges on. `merge:` and `if:` options on the existing aggregate
methods (ledger #29), grouped merged reads returning Rails-shaped hashes, the type
parser handling parametric labels like `quantile(0.95)` inside AggregateFunction
columns, and an e2e spine chapter proving events → MV → AggregatingMergeTree →
merged read. State argument types are invariant (code 70, §2).

**Phase 7 (cont.) — dialect fidelity sweep.** *(landed — Iteration 14)*
`array_join` (+ `left:`/`as:`) as a relation verb with ASOF JOIN covered through raw
string joins; relation `.settings` extended to writes via per-request HTTP parameters
(ledger #30); `codec:`/`materialized:`/`alias:` column options and
`primary_key:`/`sample:` table clauses, all introspected and schema-dumped round-trip
(ledger #31); partition lifecycle verbs on the PARTITION ID literal form (ledger #32).
Suite: 353 examples green; harness unchanged (801 runs, 0 failures, 91 skips).

**Phase 6 (cont.) — relations_test corpus.** *(landed — Iteration 15)*
Vendored `relations_test.rb` (2,784 lines, 327 new runs) with its transitive models
(bird, dats/*, engine, reader, wheel), fixtures (tags, taggings, categories_posts,
cpk_orders) and eight new slice tables. Three adapter gaps surfaced and fixed TDD:
no-op savepoint verbs (ledger #33), bare join column names (ledger #34),
backtick-aware identifier matchers (ledger #35). Ten new skips, each a documented
server limitation (no unique constraints / no rollback / functional-dependency
GROUP BY / alias shadowing / table-named column vs qualified star / cpk prefetch).
Suite: 363 examples green; harness 1,128 runs, 0 failures, 101 skips.

**Phase 6 (cont.) — associations corpus.** *(landed — Iteration 16, Track A)*
Vendored `belongs_to_associations_test` + `has_many_associations_test` byte-exact
(+29 models incl. `sharded/*`, `cpk/*`, `admin/user`; +13 fixture sets; +31 slice
tables). Two adapter gaps surfaced and fixed TDD: ordered/limited mutations now
count via the same `WHERE pk IN (subquery)` rewrite Rails compiles them into
(ledger #36), and the Arel visitor keeps column qualifiers inside nested SELECTs
so joined deletes stop tripping AMBIGUOUS_COLUMN_NAME. Helper shim grew
`WaitForAsyncTestHelper`, the global-thread-pool async executor, `reset_callbacks`,
and YAML-alias loading for skips.yml. Harness: **1,619 runs, 0 failures, 138 skips**
(64 manifest, 74 capability self-skips). Suite: 369 examples green.

**Phase 7 (cont.) — RowBinary read wire + insert_stream.** *(landed — Iteration 16, Track B)*
`RowBinary` decoder (one flat lambda table per type family off the TypeParser AST)
behind `HTTPConnection`: binary wire by default, per-query JSON fallback on
`Undecodable`, `select_format: :json` escape hatch (ledger #37). All families the
JSON wire handled decode to identical Ruby values (38-example matrix, incl.
Int128/256, Decimal256, DateTime64 tz, Enum labels, named Tuples, invalid-UTF-8
bytes). `insert_stream` streams Enumerables as chunked `JSONCompactEachRow` POSTs
(ledger #38). Baseline: 10k-row select 13.2 → 23.5 i/s and 26.6 → 10.6 MB;
1k-row ingest 26.6 ms (`insert_all!`) → 5.6 ms; 100k lazy rows in one 336 ms
request. Suite: 415 examples green; harness unchanged.

**Phase 8 — Production hardening.** *(TLS done — Iteration 17)*
TLS: verification ON by default, `ssl_verify: false` escape hatch for self-signed sinks,
proven against a real HTTPS listener in the compose file (self-signed cert in
spec/support/tls). Still open: cluster/`ON CLUSTER` DDL, Replicated/Distributed engine
support in the DSL, multi-replica round-robin with health-aware failover, read-only user
support (`prevent_writes` integration).

**Phase 9 — Real-world integration + release.** *(integration proven — Iteration 17)*
TRMNL core ported on the `clickhouse-adapter-port` worktree
(`~/Documents/GitHub/core.worktrees/adapter-port`): Gemfile swapped from
`clickhouse-activerecord 1.6.7` to this gem (path source), all 10
`db/migrate_clickhouse` migrations ran verbatim, `clickhouse:record_deploy` and the
Telemetry write/read paths work live, and every ClickHouse-touching core spec passes
with `CLICKHOUSE_PROOF_REQUIRED=true` (telemetry proof, models, log feed, activity
log, admin dashboards, logs-tab feature specs — ~250 examples, 0 failures). Zero
query changes needed; the only core-side edits were the Gemfile, one rake-task
seam (`connection.migration_context` → `connection_pool.migration_context`), and
`ssl_verify: false` on the prod sink config (its cert is self-signed; the incumbent
never verified). Fixes it forced here: ledger #39–#41 plus the TLS escape hatch.

Release readiness *(landed — Iteration 18)*: GitHub Actions CI (Ruby 3.2/3.4/4.0 on
released AR 8.1, plus ClickHouse-latest and Rails-edge probes; every job boots the real
compose server — the Gemfile falls back to the rails/rails monorepo when the local edge
worktree is absent), ankane-style README covering the full config/query surface,
CHANGELOG seeded for 0.1.0, gemspec metadata, `gem build` verified. Still open: the
0.1.0 tag/push itself (Ikraam's call).

**Phase 6 (cont.) — basics_test corpus.** *(landed — Iteration 18)*
Vendored `base_test.rb` byte-exact (+5 models, +1 fixture set, +7 slice tables incl.
`weirds` with `a$b`/`なまえ`/`from` columns). Helper gained upstream's arunit/arunit2
named configurations and two global-config flags (`raise_on_assign_to_attr_readonly`,
`belongs_to_required_validates_foreign_key = false`); pk assignment now reaches
abstract classes that pin a table (LoosePerson). One adapter gap surfaced and fixed
TDD: local-timezone read representation (ledger #42). Harness: **1,805 runs,
0 failures, 142 skips** (all manifest-documented or capability self-skips). Suite:
429 examples green.

**Phase 6 (cont.) — has_one + habtm corpora; window sugar.** *(landed — Iteration 19)*
Vendored `has_one_associations_test` + `has_and_belongs_to_many_associations_test`
byte-exact (+17 models incl. `publisher/*`, +8 fixture sets, +22 slice tables incl.
string-keyed `countries`/`treaties` with the composite-keyed `countries_treaties`
join table). No adapter gaps — every failure fell into an established family
(query-count tallies, no-rollback, cpk prefetch, raw UPDATE/DELETE without WHERE,
HAVING alias resolution). One new test-only dev dependency: bcrypt
(`models/user` declares `has_secure_password`). Window-function relation sugar
landed TDD as `RelationWindowing` (ledger #43): `.window(:fn, *cols, as:,
partition_by:, order_by:, frame:)` on the `Querying` concern, 10 live examples
covering row_number, running sums, lag, explicit frames and injection guards.
Harness: **2,003 runs, 0 failures, 154 skips**. Suite: 441 examples green.

**Phase 6 (cont.) — through corpora + the last OLAP deferrals.** *(landed — Iteration 20)*
Vendored `has_many_through_associations_test` + `has_one_through_associations_test`
byte-exact (+14 models, +11 fixture sets, +16 slice tables incl. composite-keyed
`cpk_order_tags`) and upstream's `validations_repair_helper` into the harness shim.
Every through-suite failure fell into an established family — no adapter gaps.
Dictionaries landed TDD (ledger #44): `create_dictionary`/`drop_dictionary`/
`reload_dictionary`/`dictionaries` plus `.dict_get` relation sugar, 12 live examples.
ON CLUSTER DDL landed via `cluster:` config (ledger #45) with an embedded Keeper in
the compose file so distributed DDL is provable on one node, 9 live examples.
Projections now dump into schema.rb as `add_projection` lines parsed from
`system.projections` (ledger #46), round-tripping byte-identically. Harness:
**2,226 runs, 0 failures, 177 skips**. Suite: 465 examples green.

**Phase 6 (cont.) — AR-parity alter surface + dictionary round-trips.** *(landed —
Iteration 21)* `rename_column`, `change_column`, `change_column_null` (with the
Rails backfill default as a synchronous mutation), `change_column_comment`,
`change_table_comment`/`table_comment`, post-create `add_index`/`remove_index`,
and `create_join_table` defaulting its sorting key to the two reference columns
(ledger #47). `create_dictionary` gained `database:` for cross-database sources;
dictionaries now round-trip schema.rb and structure.sql without leaking
credentials (ledger #48) and no longer masquerade as BASE TABLEs (ledger #49).
Fixed in passing: the dumper now honors `ignore_tables` for materialized views.
Harness: **2,226 runs, 0 failures, 177 skips**. Suite: 487 examples green.

**Phase 6 (cont.) — CI matrix hardening after the first real Actions run.**
*(landed — Iteration 22)* Pushed to the private GitHub remote; four of six matrix
jobs failed and each exposed an environment truth (ledger #50/#51, §2): RuboCop
scanning CI's `vendor/bundle` (Exclude now merges with the defaults), pre-3.4
`Hash#inspect` in the dumped `settings:` option (rendered by hand now), Rails
main's `QueryIntent` seam (dual-contract `perform_query` + `skips_edge.yml` for
pinned-corpus text drift, harness green on edge at 2,227 runs / 179 skips), and
ClickHouse 26.6 drift — MODIFY COLUMN narrowing needs an in-statement DEFAULT
(placeholder `defaultValueOfTypeName` + REMOVE DEFAULT, with an explicit
stored-NULLs guard), async_insert's server default flipped on, LowCardinality
ROLLUP totals now key nil, Geometry/QBit added and Object removed from the type
catalog. Suite: 490 examples green on 25.8 and 26.6.

**Phase 6 (cont.) — migration corpus.** *(landed — Iteration 23)* Vendored 15 of
Rails' `migration/` sub-suites byte-exact (columns, column_attributes,
column_positioning, index, rename_table, change_schema, create_join_table,
references_index, references_statements, command_recorder, invalid_options,
logger, schema_definitions, change_table, + migration/helper). The harness shim
gained `InlineDDLDefaults` (implicit-id `create_table` calls become an explicit
Int64 key column + sorting key; the synthesized column carries `primary_key:`
so Rails raises its dedicated redefine error). Adapter gaps closed TDD along
the way: Rails-contract `add_index`/`remove_index`/`rename_index` (ledger #52),
`rename_table`/`rename_column` index renaming, `change_column` default
replacement semantics, `change_column_null` argument validation, dependent
skip-index drops in `remove_column`, `datetime(p)`/`timestamp(p)` in
`type_to_sql`, microsecond default precision (ledger #53), `NotNullViolation`
via `input_format_null_as_default = 0`, control-character-safe `quote_string`,
versionless-ReplacingMergeTree `ar_internal_metadata`, and Rails 7.1+
`build_change_column_definition` seams. 24 manifest skips document the honest
dialect gaps (no unique indexes, String has no limit, non-Nullable column
default, raw UPDATE statements, immutable sorting keys). Migration corpus:
**297 runs, 0 failures, 24 skips**. Suite: 516 examples green.

**Phase 6 (cont.) — matrix repair + core-cutover derisking.** *(landed —
Iteration 24)* The Iteration 23 push failed two matrix jobs: AR edge (Rails
main renamed `Column#fetch_cast_type` → `cast_type`; two pinned-text entries in
`skips_edge.yml`) and ClickHouse latest (26.6's in-statement-DEFAULT rule now
reached `change_column` through the migration corpus — the same
`defaultValueOfTypeName` placeholder + `REMOVE DEFAULT` round-trip
`change_column_null` gained in Iteration 22 applies, guarded by the stored-NULLs
check; three new authored specs, verified live on 26.6.1). Cutover derisking in
the `core.worktrees/adapter-port` worktree against the hardened alter surface:
all 14 sink migrations run verbatim on a fresh database; proof spec (12), admin
request specs (100), and model/task specs (184) all green. One core-side latent
bug found and fixed in the worktree (present with the incumbent gem too):
sink models resolve `primary_key` against the unwired Postgres pool before the
sink connects, caching a guessed `"id"` that later breaks `create!` — the four
append-only sink models now declare `self.primary_key = nil`. Suite: 524
examples green on 25.8 and the authored tier green on 26.6.

**Phase 6 (cont.) — core relation port.** *(landed — Iteration 25)* The entry
require (`activerecord-clickhouse-adapter.rb`) now loads `clickhouse/querying`
eagerly so consumer models can `include ...ClickHouse::Querying` at boot before
(or without) a ClickHouse connection loading the adapter — core's sink models
load in every environment but only production wires the sink. With that seam,
every raw-SQL read in TRMNL core (ActivityLog, LogFeed, the five admin
dashboards) ported to AR relations + the gem's `.settings` sugar in the
`adapter-port` worktree; multi-aggregate projections stay as `select` strings
(idiomatic AR). Select-alias ordering works with plain hash/symbol `order`:
Rails only table-qualifies order args found in `columns_hash`, so an alias like
`hour` renders unqualified (`ORDER BY \`hour\``), which ClickHouse resolves
(probed live — an earlier note claiming hash order breaks was wrong; it had
probed hand-qualified SQL, not Rails' rendering).

**Phase 6 (cont.) — scoping corpus.** *(landed — Iteration 26)* Vendored the
three scoping suites (`default_scoping_test`, `named_scoping_test`,
`relation_scoping_test`, 233 runs) plus their missing models
(`without_table`, `cat`, `mentor`) and schema-slice tables (`lions`,
`mentors`). Six skips, all dialect-honest: two circular self-joins
(AMBIGUOUS_IDENTIFIER — reconfirmed on 26.6 and under the legacy analyzer),
three `capture_sql.second` reads that upstream aims at the INSERT after a
BEGIN we never emit (no transactions), and one association `delete_all`
nullify whose UPDATE ClickHouse type-checks even at zero matched rows
(CANNOT_CONVERT_TYPE). Harness now 2,756 runs / 208 skips.

**Phase 6 (cont.) — autosave corpus.** *(landed — Iteration 27)* Vendored
`autosave_association_test.rb` (the write-path autosave surface: nested
attributes, marked-for-destruction, circular saves) with ten missing models
(eye/iris, molecule/electron/liquid, guitar/tuning_peg, mouse/squeak, face,
translation, cake_designer) and their schema-slice tables plus orders and
prisoners. A new harness translation rule (ledger #54) pins upstream's bare
`DELETE FROM t` cleanup statements to `WHERE 1`, un-skipping two habtm tests
in the process. 36 skips, every one an already-established seam: real-rollback
dependence (16), BEGIN/COMMIT query tallies (11), anonymous in-test models
needing a server-reported pk (6), and the composite-key prefetch seam (3).
Harness: 2,973 runs / 242 skips.

**Phase 6 (cont.) — migration_test corpus.** *(landed — Iteration 28)* Vendored
the big top-level `migration_test.rb` (63 runs in its seven classes on this
adapter — the classes guarded by `supports_bulk_alter?`/`supports_ddl_transactions?`/
`supports_advisory_locks?`/adapter checks self-exclude) plus the whole
`test/migrations/` fixture tree that `MIGRATIONS_ROOT` anchors (valid, rename,
decimal, to_copy*, and friends — the migrator/copier's raw material). Zero new
skips: the corpus exposed two real DDL gaps, both fixed in the adapter with
authored specs first (ledger #55 — decimal precision/scale rules, binary/blob
mapping). The bare-DELETE rule moved to `execute_wire_query` for Rails-main
compatibility (ledger #54), and two `skips_edge.yml` entries cover main's new
`migration_strategy` pool method that the pinned test's connection stub lacks.
Harness: 3,036 runs / 242 skips.

**Phase 6 (cont.) — nested_attributes corpus.** *(landed — Iteration 29)*
Vendored `nested_attributes_test.rb` (194 runs in its sixteen classes) with the
two missing models (entry, message — the delegated-type pair) and their slice
tables. The corpus caught one real adapter gap, fixed with an authored spec
first: attribute-less creates rendered Rails' `DEFAULT VALUES`, now
`FORMAT JSONEachRow {}` (ledger #56). Five skips, all established seams: two
BEGIN/COMMIT query tallies, three anonymous in-test models needing a
client-side pk. Harness: 3,203 runs / 247 skips.

**Phase 6 (cont.) — serialized_attribute + enum corpora.** *(landed —
Iteration 30)* Vendored `serialized_attribute_test.rb` (both classes — the
YAML-safe-load subclass reruns the whole suite) and `enum_test.rb`, 203 runs
together, with the one missing model (traffic_light) and its slice table. No
adapter gaps; the corpus instead exposed a real harness bug (ledger #57): the
manifest-skip hook ran before class setup, so skipped tests' teardowns wrote
captured-but-never-set globals back as nil, poisoning later YAML tests. The
hook moved to `after_setup`, restoring upstream's inline-skip semantics. Ten
manifest skips: one new seam (`no_last_insert_id` — raw `connection.insert`
expects the server to report the new row's id, ClickHouse has none) and the
rest anonymous-model pk. Harness: 3,406 runs / 258 skips.

**Phase 6 (cont.) — dirty + timestamp + attribute_methods corpora.** *(landed —
Iteration 31)* Vendored `dirty_test.rb`, `timestamp_test.rb`, and
`attribute_methods_test.rb` (234 runs together) with five missing models
(task, book_identifier, boolean, contact, keyboard), four slice tables
(binaries, booleans, book_identifiers, keyboards, tasks), two fixture sets,
and three upstream helper ports: the `fake` stub adapter registration
(ContactFakeColumns models connect to it), `InTimeZone`/`DdlHelper`, and
`with_temporary_connection_pool`. No adapter gaps. 37 manifest skips: one new
seam (`key_column_update` — partial_writes off makes Rails update every
column including the sorting key, which ClickHouse mutations refuse, code
420), three `no_time_type` (bonus_time rides the DateTime64 TIME stand-in),
two composite-prefetch, and the rest the anonymous-model pk seam (both suites
lean heavily on in-test `Class.new` models). Harness: 3,642 runs / 295 skips.

**Phase 6 (cont.) — defaults + reflection corpora, harness isolation.**
*(landed — Iteration 32)* Vendored `defaults_test.rb` (the adapter-guarded
classes self-exclude; DefaultNumbers/Strings/Text run in full — column
defaults round-trip untouched) and `reflection_test.rb` (the association
metadata surface) with five missing models (hotel, recipe, hardback,
user_with_invalid_relation, company_in_module), three slice tables (hotels,
recipes, hardbacks), and the `SchemaDumpingHelper` port. No adapter gaps; one
manifest skip reusing the string-limit seam. Two structural harness fixes:
suite-level `"*"` overlay entries retire a class whose own setup/teardown
breaks on that Rails version (ledger #59 — Rails main froze
`attribute_method_patterns`, erroring all 117 pinned attribute_methods tests),
and the harness subprocess now runs in its own `ar_clickhouse_compat` database
(ledger #60 — ends the shared-namespace full-gate storm for good).
Harness: 3,724 runs / 296 skips.

**Phase 6 (cont.) — datetime/time precision corpora.** *(landed —
Iteration 33)* Vendored `date_time_precision_test.rb` and
`time_precision_test.rb` (`quoting_test.rb` turned out to be in the original
harness commit already). The precision corpus drove one real adapter fix
(ledger #61): explicit `precision: nil` now maps to plain `DateTime('UTC')`,
precision >9 raises ArgumentError at DDL-build time, `change_column` mirrors
new_column_definition's key-presence defaulting, and the schema dumper follows
upstream's omit-6 / `precision: nil` conventions. Ten manifest skips: seven
`no_time_ddl` (ClickHouse has no TIME type; the adapter refuses `:time` rather
than shipping a lossy stand-in), two dumper-convention (`null: false` omitted
as the ClickHouse default), one nanosecond-bound (precision 7 is valid here;
upstream's 6 is a MySQL/Postgres cap). Harness: 3,743 runs / 306 skips.

**Phase 6 (cont.) — dumper, comments, aggregations, explain corpora.** *(landed
— Iteration 34)* Vendored four suites: `comment_test.rb`, `aggregations_test.rb`
(composed_of), and `explain_test.rb` all pass in full with zero skips — column/
table/index comments, value objects, and EXPLAIN were already exact.
`schema_dumper_test.rb` needed five slice tables (CamelCase, goofy_string_id,
integer_limits, movies, string_key_objects) and 14 convention skips, all
documenting dump-shape dialect: null: false is never dumped (non-nullable is the
ClickHouse default), text/binary round-trip as the one String type, Int64 dumps
as `t.integer limit: 8` (one integer family), the sorting key dumps as `order:`
never `primary_key:`, id columns are explicit lines (no implicit pk), and
data-skipping indexes are not btree indexes (no order/length/where). The
`SchemaDumperDefaultsTest` class retires via a `"*"` entry — its own setup DDL
uses `t.time`. No adapter changes. One flake sighting: a full-harness run
produced two interleaved Minitest summaries in one output (one process header,
two "Finished in" lines) with mass fixture-wipe failures; identical seed re-ran
green with a single summary. Mechanism unknown (the only vendored `fork` site is
manifest-skipped and exit!-guarded); treat a double-summary output as invalid
and re-run. Harness: 3,815 runs / 320 skips.

**Phase 6 (cont.) — bind parameter, column definition, inheritance corpora.**
*(landed — Iteration 35)* Vendored three suites. `column_definition_test.rb`
passes untouched (stub-adapter only). `inheritance_test.rb` (STI: compute_type,
becomes, discriminator mapping, four classes) runs 73 tests with a single skip
(the circular self-join analyzer limit, reusing `self_join_ambiguity`); it
autoloads deliberately-broken model files through a Zeitwerk loader rooted at
the new `MODELS_ROOT`, adding zeitwerk as a dev-only dependency.
`bind_parameter_test.rb` needed eight skips in two honest groups: six because
the HTTP interface has no server-side prepared statements, so the adapter keeps
no `@statements` StatementPool to introspect, and two because the adapter has no
client-side bind limit — upstream's 65k-bind probe becomes one giant inlined IN
list that trips the server's 256KB `max_query_size` (code 62) instead of Rails'
bind-inlining path. Five slice tables (collections, products, product_types,
variants, vegetables). No adapter changes. One latent seed-order bug fixed in
the harness bootstrap: several MigrationTest internal-metadata tests assume
`ar_internal_metadata`/`schema_migrations` already exist (upstream's db:prepare
rake task leaves them behind); run.rb now creates both after the schema slice,
so the tests no longer depend on whether an earlier test created them as a side
effect. The double-summary flake recurred once (seed 23574: two "Finished in"
lines, mass fixture trampling; identical seed re-ran green under a fork tracer
that recorded zero forks). run.rb now permanently stamps every Minitest summary
with its pid and prints a backtrace from any `Process._fork`, so the next
sighting names the second process. Harness: 3,908 runs / 329 skips.

**Phase 6 (cont.) — store, secure_token, counter_cache corpora; OLAP example;
double-summary flake root-caused.** *(landed — Iteration 36)* Vendored three
suites (116 runs): `store_test.rb` passes untouched (serialized/JSON store on
existing admin_users columns), `counter_cache_test.rb` needs two
`query_count_tally` skips (reset_counters emits the mutation path's COUNT(*)
probe), `secure_token_test.rb` three `anonymous_model_primary_key` skips. One
slice table (friendships). New `examples/olap_on_rails.rb`: a runnable
narrated tour (fact table → insert_stream → prewhere/limit_by/group_by_period/
rollup/window/dict_get → aggregate-state pipeline with merge: true →
ReplacingMergeTree + final → partitions/EXPLAIN/instrumentation), guarded by
`spec/examples/olap_on_rails_spec.rb` running it as a subprocess in its own
database. **The double-summary flake is root-caused and fixed:** the pid stamp
caught two complete rspec gates writing one redirect file (seeds 33333/37380,
pids 86594/79931), and `system.query_log` showed one harness's alphabetical
TRUNCATE fixture sweep interleaved microsecond-level with the other's test
queries — two concurrent full gates sharing `ar_clickhouse_compat`, i.e. a
one-driver-rule violation, not an adapter or harness bug. The harness database
is now pid-suffixed (`ar_clickhouse_compat_<pid>`, dropped at_exit), making
cross-run trampling mechanically impossible; the fork tracer is gone, the pid
stamp stays. The 21 `Cancelled mutating parts` (code 341) errors in trampled
runs were the concurrent TRUNCATEs aborting in-flight mutations. Harness:
4,024 runs / 334 skips.

**Phase 6 (cont.) — query_cache plus twelve type/relation corpora.** *(landed —
Iteration 37)* Vendored thirteen suites (194 runs). `query_cache_test.rb`
needed the upstream `clean_up_connection_handler` helper ported into the
TestCase reopen and three skips: no row locks (FOR UPDATE is a syntax error),
rollback leak (transactions are no-ops), and the threads-share-a-connection
expiry test (upstream pins via transactional fixtures' lock_thread). Of the
twelve small suites — binary, boolean, date, date_time, numeric_data,
json_attribute (+ json_shared_test_cases), null_relation, excluding,
column_alias, dup, clone, sanitize — nine pass untouched, including sanitize
(quoting) and numeric_data (Decimal128 round-trips). Honest skips: BinaryTest's
three encoding tests (one String type — bytes round-trip but the ASCII-8BIT
tag is unrecoverable), DateTimeTest's 1807 round-trip (DateTime64 clamps below
its 1900-01-01 floor, probed live), and JsonAttributeTest's three (NULL
payloads on the adapter's non-nullable-by-default DDL; raw UPDATE without
WHERE). No adapter changes. Harness: 4,218 runs / 345 skips.

**Phase 6 (cont.) — batches plus five attribute/identity corpora.** *(landed —
Iteration 38)* Vendored six suites (216 runs). `batches_test.rb` (116 runs,
find_each/in_batches/BatchEnumerator) needs only four skips: two
`query_count_tally` (the mutation path's per-batch COUNT probe), the
whole-table DELETE regex (mutation WHERE clauses render unqualified column
names — the ALTER DELETE grammar has no table-qualified references), and the
unique-cursor check (`add_index` makes data-skipping indexes, never UNIQUE).
`normalized_attribute_test`, `secure_password_test`, and `signed_id_test`
pass untouched — has_secure_password and signed_id just work.
`multiparameter_attributes_test` skips five: four are ledger #23 made visible
(writes encode UTC, so Time.local round-trips keep the wall clock but lose
the zone) plus one `no_time_type`. `cache_key_test` skips three under a new
`no_raw_timestamp_string` anchor: RowBinary type-casts at the wire, so
`updated_at_before_type_cast` is already a Time, not the raw string
cache_version's no-cast fast path expects. One flake-by-design skip added
after the full gate: SecurePasswordTest's constant-time assertion (0.5s
wall-clock tolerance) is load-sensitive under the harness. No adapter
changes. Harness: 4,434 runs / 358 skips.

**Phase 6 (cont.) — eight corpora plus two adapter fixes.** *(landed —
Iteration 39)* Vendored `delegated_type`, `readonly`, `touch_later`,
`attributes`, `annotate`, `filter_attributes`, `result`, and `instrumentation`
(126 runs). Two adapter changes fell out, both TDD'd live. First:
`notification_payload[:affected_rows]` is now populated from the server
summary's written_rows on every wire query and on insert_stream — upstream's
InstrumentationTest exposed that we left Rails' default 0 in place. Second:
datetime/date columns now expose `ActiveRecord::Type::DateTime`/`::Date`
(not the ActiveModel ones): they respect `ActiveRecord.default_timezone`, and
Rails' time-zone-aware attribute machinery type-checks for them
(CustomPropertiesTest#test_time_zone_aware_attribute). Six skips: three
`string_limit_not_persisted` (ClickHouse String is unbounded, so :string
limits never reach DDL and can't round-trip), one anonymous-model
`Model.last`, and InstrumentationTest's two affected-rows tallies (the
mutation COUNT probe adds events and ALTER UPDATE/DELETE write no rows, so
the per-event sequence can't match upstream's). delegated_type, readonly,
annotate, filter_attributes, and result pass untouched. Mid-iteration the
Docker Desktop VM wedged (zombie container, daemon EOF) — a full Docker
restart plus compose reset recovered it. Harness: 4,560 runs / 365 skips.

**Phase 6 (cont.) — nine loading/serialization corpora plus an annotation
fix.** *(landed — Iteration 40)* Vendored `strict_loading`, `validations`,
`view`, `unsafe_raw_sql`, `reserved_word`, `relation`, `serialization`,
`json_serialization`, and `yaml_serialization`. One adapter fix fell out:
`ALTER TABLE … UPDATE` mutations now carry relation annotations
(`maybe_visit o.comment` was missing from the update visitor — AnnotateTest
had covered SELECTs only). Harness plumbing: upstream's `TEST_ROOT`/
`FIXTURES_ROOT` path constants and the `create_fixtures` helper now exist
(ReservedWordTest and YamlSerializationTest reach static fixture files
through them); `clean_up_connection_handler` no longer strips fake-adapter
pools (Contact/ContactSti are load-time fixtures — upstream rebuilds them
per file-process, this harness is one process); and the `PRIMARY_KEYS`
manifest now wins outright over the lazy `table_exists?` guess, because
ReservedWordTest's scratch tables (`distinct`, `group`, `select`, `values`)
exist only inside its setup/teardown. Five skips, each a known seam:
StrictLoadingTest's n_plus_one has_many case (unordered loads are
part-dependent — `.last` may hit a nil FK that belongs_to short-circuits),
an anonymous-model find (ledger #7), COLLATE (upstream's per-adapter
collation map has no entry, and ClickHouse takes a string literal anyway),
and `SELECT t.* GROUP BY t.id` (no functional-dependency GROUP BY —
NOT_AN_AGGREGATE, same seam as CalculationsTest). validations, view,
relation, and json_serialization pass untouched. Harness: 4,792 runs /
369 skips.

**Phase 6 (cont.) — adapter-surface corpora + two adapter fixes.** *(landed —
Iteration 41)* Vendored six suites: `adapter_test`, `database_statements_test`,
`primary_keys_test`, `statement_invalid_test`, `table_metadata_test`, and
`types_test` (plus upstream's `support/connection_helper.rb`). Three adapter
changes fell out. (1) `lookup_cast_type` now routes through the gem's type
parser instead of the abstract TYPE_MAP, whose SQL-name pattern-matching
degrades ClickHouse shapes (`Nullable(...)`, `UUID`, `Map`) to `Type::Value`
and even false-matches `Tuple(String, Int64)` as Integer; results are frozen so
lookups stay Ractor-shareable like Rails' own maps (adapter_test's Ractor
assertions). A class-level `native_database_types` joins it — Rails'
class-level `valid_type?` reads it off the class. (2) `create_table` with a
composite `primary_key:` array now renders a quoted PRIMARY KEY tuple, and a
PRIMARY KEY clause alone satisfies the sorting-key requirement — the server
infers ORDER BY from it (probed live; forcing `order: "tuple()"` alongside
raises BAD_ARGUMENTS, primary key longer than sorting key). (3) `disconnect!`
now closes the raw HTTP connection *inside* `@lock` (the postgresql adapter's
own pattern): queries hold the lock for their whole round-trip, so closing
after release let a queued query start its read on a dying socket — surfaced
live as IOError in the vendored AdapterThreadSafetyTest, pinned by a
deterministic spec asserting `mon_owned?` at close time. Skips, all honest
seams: AdapterForeignKeyTest retires class-level (no FK constraints — the
InvalidForeignKey path is untestable and its fixtures fail in before_setup);
AdapterThreadSafetyTest's two synchronization probes (this harness is
transactionless, so no lock_thread pinning ever installs a real Monitor —
upstream only passes because fixtures pin); AdapterConnectionTest self-skips
through upstream's own seam (`remote_disconnect`/`raw_transaction_open?`/
`connection_id_from_server` helpers skip for adapters they can't drive, now
mirrored in ARCompat::AdapterHelper); plus dump-shape and no-reported-pk
entries on the primary-keys suites. One authored-spec honesty fix: `active?`
is false on a virgin connection (connecting is lazy), so the connection spec
verifies first — was seed-order dependent. Environment note: a concurrent
harness run from a second session saturated the container (225,000% CPU,
Docker VM death #4); the pid-suffixed harness database contained the data
blast radius, but the box does not survive two full gates. Harness: 4,918
runs / 429 skips.

**Phase 6 (cont.) — sixteen small corpora + encoding fix.** *(landed —
Iteration 42)* Vendored sixteen suites in two batches: callbacks, core,
modules, mixin, i18n, finder_respond_to, suppressor; then
asynchronous_queries, query_logs, collection_cache_key,
marshal_serialization, forbidden_attributes_protection, token_for,
primary_class, inherited, active_record. Thirteen pass with zero skips —
callbacks, async queries (including the executor-type matrix), token_for,
forbidden-attributes protection, and query logs were already exact. One
adapter fix fell out: SQL carrying invalid UTF-8 bytes died in
`hoist_trailing_comments`' regexes (ArgumentError) before reaching the
server; it now drops to binary first, because ClickHouse strings are byte
sequences and the patterns are pure ASCII (upstream QueryLogsTest proves
every non-Postgres adapter accepts such SQL). Live probe recorded: the
server accepts raw invalid bytes in string literals and backtick
identifiers, but upstream's own probe (`SELECT 1 AS 'x'`) aliases with a
*quoted string*, which ClickHouse rejects as a syntax error regardless of
encoding — that one test skips on dialect, with the adapter-side behavior
spec'd in query_comments_spec. Other skips: CoreTest's two pretty_print
expectations (bonus_time is a :time column upstream, date part coerced to
2000-01-01; no TIME type here so the fixture's real date shows through) and
MarshalSerializationTest's four historical-dump replays (upstream ships
per-adapter dumps recorded on Rails 6.1/7.1 — no honest ClickHouse dump can
exist). Slice grew notifications + mixins tables and collections/products/
variants/mixins fixtures. One edge-overlay entry: Rails main refactored
`Arel::Table.new` to a keyword `name:` argument (b1650993b0), which the
pinned table_metadata test constructs positionally. Harness: 5,125 runs /
437 skips.

**Phase 6 (cont.) — locking, subscribers, and the associations umbrella.**
*(landed — Iteration 43)* Vendored eight suites: statement_cache,
nested_attributes_with_callbacks, habtm_destroy_order, custom_locking, and
explain_subscriber pass with zero skips. Two Arel visitor additions fell out,
each spec'd live in dialect_spec: `matches`/`does_not_match` now render
ClickHouse's native ILIKE for the case-insensitive default (LIKE here is
case-sensitive, unlike MySQL; same shape as the postgresql visitor) and refuse
custom ESCAPE characters loudly (no ESCAPE clause exists — backslash is fixed);
FOR UPDATE drops silently from the SQL like the sqlite3 visitor, because reads
are isolated snapshots of parts and no row locks exist — so shared
`Model.lock`/`with_lock` code keeps working. With that, optimistic locking
passes end-to-end (stale writes match zero rows via the lock_version predicate
and raise StaleObjectError) and pessimistic tests reduce to plain reads; the
locking corpus carries five skips on existing seams (query-count tallies,
key-column update, rollback) plus log_subscriber's two binary-bind redaction
tests (one byte-safe String type — no binary cast type exists to trigger
Rails' "<N bytes>" placeholder). The associations umbrella (AssociationsTest,
PreloaderTest, GeneratedMethodsTest, WithAnonymousClassTest, ...) runs with
two skips (composite prefetch, key-column update). Slice grew the cpk_cars
composite-key pair and the locking/discount-application tables. Harness:
5,380 runs / 445 skips.

**Phase 6 (cont.) — migrator, structured events, and the fixtures machinery.**
*(landed — Iteration 44)* Vendored three suites. `migrator_test.rb` passes in
full — the Migrator's up/down/status bookkeeping sits entirely on
schema_migrations, which the adapter already models exactly.
`structured_event_subscriber_test.rb` skips only the two binary-bind
redaction tests (same one-String-type seam as log_subscriber).
`fixtures_test.rb` is the big one: 130 runs covering ERB fixture rendering,
custom fixture paths (naked/yml), nested fixture directories, instantiated
fixtures, HABTM fixture linking, and fixture accessors — three skips. Two are
familiar dialect (a t.time DDL clone; the JPEG blob whose bytes round-trip
exactly but read back UTF-8-tagged, since with one String type no binary cast
type exists to force ASCII-8BIT). The third group is structural:
`TransactionalFixturesTest` opts into use_transactional_tests, whose whole
point is that a destroy rolls back — with honest no-op transactions the
destroy is real and the sibling test dies in before_setup instantiating the
now-missing fixture, so the class retires via "*" (decision #15's truncate +
reload is the substitute). The slice grew the fk_test trio,
items/doubloons/randomly_named tables, cpk_posts_tags, and the harness now
carries upstream's auxiliary fixture directories (all/, naked/, categories/,
primary_key_error/, to_be_linked/) plus ASSETS_ROOT for the binary-fixture
ERB. One environmental reconfirmation: a long-uptime tmpfs container hit
NOT_ENOUGH_SPACE mid-run and cascaded 29 nil-permitted-classes errors through
SerializedAttributeTestWithYamlSafeLoad; the identical corpus was green on a
fresh container — reset before blaming the harness. Harness: 5,558 runs /
450 skips.

**Phase 8 — failover + read-only connections.** *(landed — Iteration 45)*
Multi-replica `hosts:` on the HTTP connection (decision #62): round-robin
start positions across connections, rotation on connect-phase errors only
(a request that never reached a server cannot double a write; mid-flight
failures raise), a process-wide cooldown ledger (`failover_cooldown:`,
default 30s) so fresh connections skip recently refused endpoints — no
health-check pings, no threads. `read_only: true` stamps `readonly=2` on
every request (decision #63); the server's code-164 refusal translates to
`ActiveRecord::ReadOnlyError` (matching `while_preventing_writes`), and
grant refusals (code 497) raise the new `ClickHouse::AccessDenied`.
Landing the branch surfaced two doc-rot fixes: the TRMNL corpus snapshot
re-pinned to core @ b66bbb90b (27 migrations — fetches, pool_events,
process_health, four new event_type enum values), and write_settings
specs updated for the ReadOnlyError translation. Suite: 570 examples
green; harness unchanged (5,558 runs, 0 failures, 451 skips).

**Phase 8 (cont.) — primary-key auto-detection + Rails-style id: tables.**
*(landed — Iteration 46)* Decision #64 (approved): `primary_keys(table)`
reports a single-column U/Int64+/UUID sorting key as Active Record identity
— the same gate as the client-side id generator, one cached lookup serving
both — so id-keyed tables are drop-in with zero model boilerplate; composite,
expression, and non-id keys still report `[]` (index prefix, not identity),
with explicit `self.primary_key` as the seam for by-design-unique keys. The
dumper suppresses reporting to keep the `id: false` + `order:` dump shape.
`create_table id: :bigint/:uuid/:primary_key` works without `order:` (the pk
column is its own sorting key; `:primary_key` maps to plain Int64).
`Errno::ENETUNREACH` joined CONNECT_ERRORS (added blind, approved — connect-
phase by nature, unreproducible in the container). Harness fallout: the
`PRIMARY_KEYS` slice map now assigns explicit nils (detection would otherwise
claim synthesized id sorting keys on upstream's pk-less tables — FinderTest
caught it), and four skips erased (PrimaryKeysTest auto-detect/prefix/
returns-value, PrimaryKeyWithAutoIncrementTest bigint). Suite: 585 examples
green; harness 5,558 runs, 0 failures, 447 skips.

## 7. Spec strategy (three tiers)

1. **Authored RSpec** (`spec/`) — the TDD driver. Named subjects, one expectation per
   example, `context` per setup change. Every spec hits the live server; suite creates and
   drops its own scratch tables under `ar_clickhouse_test`.
2. **Ported Rails suite** (`spec/rails_compat/`) — vendored minitest cases pinned to a
   rails SHA + `skips.yml` manifest. Ratchet: the manifest may only shrink.
3. **Ported ClickHouse suite** (`spec/clickhouse_compat/`) — curated `.sql`/`.reference`
   pairs from `0_stateless` replayed through the adapter (statement in → result out must
   match the `.reference`), proving our SQL generation and casting agree with the server's
   own test corpus.

### Version matrix policy

One pinned corpus, version overlays, a live-server matrix — never dynamic fetching of
upstream test repos in CI (that trades away determinism and the ratchet):

- **Corpus pin**: the vendored Rails suites track the newest *released* Rails
  (`vendor/UPSTREAM`). When a new minor ships: re-pin the corpus to it in one commit,
  regenerate skips against the live server, and move the previous version's drift into a
  `skips_*.yml` overlay (registry in `support/cases/helper.rb`, predicate per overlay).
  Overlays quarantine drift in upstream *test text*; behavioral differences stay in
  `skips.yml` or get fixed. Delete an overlay when its version leaves the support window.
- **Server floor**: ClickHouse 25.8 (the oldest LTS in CI). Older LTS lines fail on
  wire-format and analyzer differences (probed 25.3, 2026-07-14: RowBinary JSON columns,
  window frames, EXPLAIN shapes) and are explicitly unsupported. `latest` runs in the CI
  matrix; `head` (nightly) runs in the weekly drift workflow.
- **Drift detection**: `.github/workflows/drift.yml` runs Rails main and ClickHouse head
  weekly, decoupled from merge-gating CI. A red drift run means: probe live, add the
  grounding fact to §2, fix or overlay, before it reaches a release.
- **Acceptance corpus**: TRMNL core's migrations are snapshotted byte-exact in
  `spec/vendor/trmnl_corpus/` (its UPSTREAM records the source SHA) so CI exercises them;
  a local `../core` checkout takes precedence to surface drift before the snapshot stales.

## 8. Environments

- **This repo:** `docker compose up -d --wait` → `clickhouse-server:25.8` on
  `localhost:18123` (tmpfs storage: disposable, merge-fast). `CLICKHOUSE_*` env overrides
  for CI. `RAILS_SOURCE=edge bundle` pins Active Record to `../rails-main/activerecord`.
- **TRMNL core:** the consumer app — its compose files, telemetry models, and 16 live
  migrations are the reality check (Phase 3 corpus, Phase 9 e2e).
- **CI (later):** GitHub Actions service containers, matrix per Phase 9.

## 9. Risks / open questions

- **Rails-suite fixture load** requires transactional wrapping by default — the compat
  harness must force non-transactional fixtures + table truncation; some suites may be
  permanently manifest-skipped. Acceptable: the manifest documents the database's honest
  semantics. *(Resolved Iteration 8: TRUNCATE-based `insert_fixtures_set` override,
  `use_transactional_tests = false` in the shim — calculations_test runs clean.)*
- **Client-side primary-key generation** *(resolved Iteration 9, option (a) approved by
  Ikraam — decision #19)*: adapter-level prefetch generates time-ordered Int64 or UUIDv7
  ids when the sorting key is one generatable column; all 16 related calculations_test
  skips now pass. Residual cost: one `system.tables` SCHEMA query per `create!`
  (Rails does not cache `prefetch_primary_key?` per model) — candidate for caching if
  insert-path profiling ever flags it.
- **RowBinary in pure Ruby** beat JSON parsing across every benchmarked shape
  (Iteration 16: 1.8–2x on selects, string-heavy included), so it shipped as the default;
  a native extension stays out of scope. The residual risk is new server types without a
  binary decoder — those fall back to the JSON wire per query, so they degrade, not break.
- **`UPDATE` semantics drift** across CH versions (lightweight update GA is moving) —
  capability detection by server version + probe, matrix-tested against LTS and latest.
- **AR internals churn** on `main` — the QueryIntent pipeline rewrite (above) is already
  live on main; the `RAILS_SOURCE=edge` job is allowed to fail without blocking, but its
  failures feed the roadmap early.
- **Relation extensions without monkeypatches** — `.final`/`.settings`/`.prewhere` need
  per-relation state; Rails has no public seam for new relation values. Plan: carry state in
  Arel node wrappers built from adapter-owned scopes/extending modules, and treat any
  unavoidable prepend as a quarantined, version-guarded `compat/` file with its own specs —
  never inline reopens. This is the one area where "zero monkeypatches" may soften to
  "minimal, quarantined, tested".
