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
