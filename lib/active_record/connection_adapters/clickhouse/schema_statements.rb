# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      module SchemaStatements
        NON_TABLE_ENGINES = %w[View MaterializedView LiveView].freeze

        # ClickHouse has no autoincrement; tables default to no id column and the
        # sorting key acts as the primary key.
        def create_table(table_name, id: false, **options, &block)
          clear_generatable_primary_key_cache
          options = internal_table_options(table_name, options)
          # With id: false Rails' own primary_key: kwarg is inert, so the DSL reuses the
          # ClickHouse clause name; renamed here because super would swallow it. With an
          # explicit id column the Rails meaning (pk column name) wins untouched.
          options[:primary_key_clause] = options.delete(:primary_key) if id == false && options.key?(:primary_key)
          super
        end

        def drop_table(*, **)
          clear_generatable_primary_key_cache
          super
        end

        # HABTM join tables have an obvious sorting key: the two reference columns —
        # unless they are nullable (sorting keys reject Nullable columns, PLAN.md §2).
        def create_join_table(first_table, second_table, **options)
          options[:order] ||= join_table_sorting_key(first_table, second_table, options)
          super
        end

        def rename_table(table_name, new_name, **)
          clear_generatable_primary_key_cache
          validate_table_length!(new_name.to_s)
          execute("RENAME TABLE #{quote_table_name(table_name)} TO #{quote_table_name(new_name)}#{on_cluster_clause}")
          rename_table_indexes(table_name, new_name)
        end

        def remove_column(table_name, column_name, type = nil, **options)
          return if options[:if_exists] == true && !column_exists?(table_name, column_name)

          # The DROP mutation refuses to break a skip index (UNKNOWN_IDENTIFIER,
          # probed 2026-07-14); Rails semantics drop dependent indexes with the column.
          indexes(table_name).each do |index|
            remove_index(table_name, name: index.name) if index.columns.include?(column_name.to_s)
          end
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            #{remove_column_for_alter(table_name, column_name, type, **options)}
          SQL
        end

        # The server rewrites skip-index expressions to the new column name itself
        # (probed 2026-07-14); Rails' shared helper then renames auto-named indexes.
        def rename_column(table_name, column_name, new_column_name)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}
          SQL
          rename_column_indexes(table_name, column_name, new_column_name)
        end

        # No RENAME INDEX in ClickHouse (probed 2026-07-14) — drop and re-add. New
        # parts index immediately; existing parts after MATERIALIZE INDEX, same
        # contract as add_index.
        def rename_index(table_name, old_name, new_name)
          validate_index_length!(table_name, new_name.to_s)
          index = indexes(table_name).find { |candidate| candidate.name == old_name.to_s }
          raise ArgumentError, "no such index #{old_name} in #{table_name}" unless index

          remove_index(table_name, name: old_name)
          add_index(table_name, index.columns, name: new_name, using: index.using, granularity: index.granularity)
        end

        # MODIFY COLUMN takes the full new definition; existing rows are cast in a
        # mutation, so incompatible narrowing surfaces as a server error. Like Rails,
        # the new definition fully replaces the old: an omitted default clears an
        # existing one (the server keeps it through a bare type change, probed 2026-07-14).
        def change_column(table_name, column_name, type, **options)
          sql_type = changed_column_sql_type(type, options)
          new_default = options.key?(:default) && !options[:default].nil?
          default_clause =
            if new_default
              " DEFAULT #{quote(options[:default])}"
            elsif !options[:null]
              narrowing_placeholder_default(table_name, column_name, sql_type)
            end
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            MODIFY COLUMN #{quote_column_name(column_name)} #{sql_type}#{default_clause}
          SQL
          change_column_default(table_name, column_name, nil) unless new_default
        end

        # Dry-run seams (Rails 7.1+): describe the change without executing it.
        def build_change_column_definition(table_name, column_name, type, **)
          definition = create_table_definition(table_name)
          ChangeColumnDefinition.new(definition.new_column_definition(column_name, type, **), column_name)
        end

        def build_change_column_default_definition(table_name, column_name, default_or_changes)
          column = column_for(table_name, column_name)
          return unless column

          ChangeColumnDefaultDefinition.new(column, extract_new_default_value(default_or_changes))
        end

        # Narrowing to non-Nullable would silently rewrite stored NULLs to the type
        # default (26.6+) or fail mid-mutation (25.8, code 349), so the Rails backfill
        # default runs first as a synchronous mutation and is required when NULLs exist.
        def change_column_null(table_name, column_name, null, default = nil)
          validate_change_column_null_argument!(null)

          column = columns(table_name).find { |candidate| candidate.name == column_name.to_s }
          raise ArgumentError, "no such column #{column_name} in #{table_name}" unless column

          inner_type = column.sql_type.sub(/\ANullable\((.*)\)\z/m, '\1')
          return widen_column_to_nullable(table_name, column_name, inner_type) if null

          if default.nil?
            assert_no_stored_nulls(table_name, column_name)
          else
            backfill_nulls(table_name, column_name, default)
          end
          narrow_column(table_name, column_name, inner_type, column)
        end

        # The insert-trigger half of the OLAP ingest-raw/read-aggregated idiom. A TO
        # target is required: inner-storage views hide data in an implicit table and
        # POPULATE misses concurrent inserts, so neither is supported.
        def create_materialized_view(view_name, to: nil, as: nil)
          raise ArgumentError, "create_materialized_view requires to: (a target table)" if to.nil?
          raise ArgumentError, "create_materialized_view requires as: (a SELECT)" if as.nil?

          execute(<<~SQL.squish)
            CREATE MATERIALIZED VIEW #{quote_table_name(view_name)}
            TO #{quote_table_name(to)} AS #{as}
          SQL
        end

        def drop_materialized_view(view_name, if_exists: false)
          execute("DROP VIEW #{"IF EXISTS " if if_exists}#{quote_table_name(view_name)}")
        end

        # Projections are per-part alternate physical layouts (sort orders or
        # pre-aggregations) the optimizer picks automatically; materialize_projection
        # backfills parts written before the projection existed (async mutation).
        def add_projection(table_name, projection_name, select: "*", order: nil, group: nil)
          body = ["SELECT #{select}"]
          body << "GROUP BY #{group}" if group
          body << "ORDER BY #{order}" if order
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}
            ADD PROJECTION #{quote_column_name(projection_name)} (#{body.join(" ")})
          SQL
        end

        def drop_projection(table_name, projection_name, if_exists: false)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}
            DROP PROJECTION #{"IF EXISTS " if if_exists}#{quote_column_name(projection_name)}
          SQL
        end

        def materialize_projection(table_name, projection_name)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}
            MATERIALIZE PROJECTION #{quote_column_name(projection_name)}
          SQL
        end

        # Dictionaries replace star-schema dimension JOINs with in-memory lookups.
        # Columns are inferred from the source table, and the SOURCE clause carries the
        # adapter's credentials — the dictionary's own loader authenticates separately
        # and would otherwise connect as `default` (probed 2026-07-14).
        def create_dictionary(name, source:, primary_key:, layout: :flat, lifetime: 300, database: nil)
          execute(<<~SQL.squish)
            CREATE DICTIONARY #{quote_table_name(name)} (#{dictionary_columns(source, database)})
            PRIMARY KEY #{quote_column_name(primary_key)}
            SOURCE(CLICKHOUSE(#{dictionary_source(source, database)}))
            LAYOUT(#{dictionary_layout(layout)})
            LIFETIME(#{dictionary_lifetime(lifetime)})
          SQL
        end

        def drop_dictionary(name, if_exists: false)
          execute("DROP DICTIONARY #{"IF EXISTS " if if_exists}#{quote_table_name(name)}")
        end

        def dictionaries
          select_values(<<~SQL.squish, "SCHEMA")
            SELECT name FROM system.dictionaries WHERE database = currentDatabase() ORDER BY name
          SQL
        end

        def reload_dictionary(name)
          execute("SYSTEM RELOAD DICTIONARY #{quote_table_name(name)}")
        end

        # Partition lifecycle: the OLAP replacement for bulk deletes and archival. All
        # verbs take the partition_id string (see #partitions) — the ID form is a plain
        # quoted literal, so arbitrary expressions never reach the ALTER.
        def partitions(table_name)
          select_values(<<~SQL.squish, "SCHEMA")
            SELECT DISTINCT partition_id FROM system.parts
            WHERE database = currentDatabase() AND table = #{quote(table_name.to_s)} AND active
            ORDER BY partition_id
          SQL
        end

        def detach_partition(table_name, partition_id)
          alter_partition(table_name, "DETACH", partition_id)
        end

        def attach_partition(table_name, partition_id)
          alter_partition(table_name, "ATTACH", partition_id)
        end

        def drop_partition(table_name, partition_id)
          alter_partition(table_name, "DROP", partition_id)
        end

        # Hard-links the partition into shadow/<name> as an instant local backup.
        def freeze_partition(table_name, partition_id, name: nil)
          alter_partition(table_name, "FREEZE", partition_id, suffix: name && " WITH NAME #{quote(name)}")
        end

        # Forces an unscheduled merge; FINAL merges down to one part per partition —
        # the maintenance verb that makes ReplacingMergeTree deduplication actually
        # happen instead of eventually.
        def optimize_table(table_name, final: true)
          execute("OPTIMIZE TABLE #{quote_table_name(table_name)}#{" FINAL" if final}")
        end

        # MODIFY COLUMN accepts DEFAULT without restating the type; REMOVE DEFAULT
        # drops it (probed 2026-07-13) but errors when none exists (code 36, probed
        # 2026-07-14) — Rails treats clearing an absent default as a no-op.
        def change_column_default(table_name, column_name, default_or_changes)
          default = extract_new_default_value(default_or_changes)
          alteration = default_alteration_clause(table_name, column_name, default)
          return unless alteration

          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            MODIFY COLUMN #{quote_column_name(column_name)} #{alteration}
          SQL
        end

        def tables
          select_values(data_source_sql(type: "BASE TABLE"), "SCHEMA")
        end

        def views
          select_values(data_source_sql(type: "VIEW"), "SCHEMA")
        end

        def table_exists?(table_name)
          tables.include?(table_name.to_s)
        end

        def view_exists?(view_name)
          views.include?(view_name.to_s)
        end

        def data_sources
          select_values(data_source_sql, "SCHEMA")
        end

        def data_source_exists?(name)
          data_sources.include?(name.to_s)
        end

        # ClickHouse PRIMARY KEY is an index prefix, not a uniqueness guarantee, so no
        # column is safe to expose as an Active Record primary key.
        def primary_keys(_table_name)
          []
        end

        def indexes(table_name)
          skipping_indices_sql = <<~SQL.squish
            SELECT name, expr, type_full, granularity FROM system.data_skipping_indices
            WHERE database = currentDatabase() AND table = #{quote(table_name.to_s)}
          SQL

          select_all(skipping_indices_sql, "SCHEMA").map do |row|
            ClickHouse::IndexDefinition.new(
              table_name.to_s, row["name"],
              # The server stores the expression bare ("a, b", probed 2026-07-14);
              # Rails' index helpers expect a column-name array.
              columns: row["expr"].split(", "), using: row["type_full"], granularity: row["granularity"]
            )
          end
        end

        def valid_table_definition_options
          super + %i[engine order partition ttl settings primary_key_clause sample]
        end

        def valid_column_definition_options
          super + %i[low_cardinality codec materialized alias]
        end

        # Rails' schema_migrations/ar_internal_metadata bookkeeping arrives via fixed
        # create_table calls; give those tables an append-safe ReplacingMergeTree shape.
        def internal_string_options_for_primary_key
          {}
        end

        def type_to_sql(type, limit: nil, precision: nil, scale: nil, **)
          case type.to_s
          when "integer" then integer_to_sql(limit)
          when "bigint" then "Int64"
          # binary/blob included: ClickHouse String is an arbitrary byte sequence.
          when "string", "text", "binary", "blob" then "String"
          when "float" then "Float64"
          when "decimal", "numeric" then decimal_to_sql(precision, scale)
          # Rails' shared tests pass mysql-style parenthesized precision ("datetime(6)").
          # A nil precision here was explicit — Rails injects 6 for a bare t.datetime —
          # so it means the second-precision base type, like MySQL's plain datetime.
          when /\A(?:datetime|timestamp)(?:\((\d+)\))?\z/
            datetime_to_sql(Regexp.last_match(1) || precision)
          when "date" then "Date32"
          when "boolean" then "Bool"
          when "uuid" then "UUID"
          when "json" then "JSON"
          else
            clickhouse_type_verbatim(type)
          end
        end

        # Everything system.tables knows about the table beyond columns, in the shape
        # our create_table DSL accepts — this is what the schema dumper emits.
        def table_options(table_name)
          row = select_one(<<~SQL.squish, "SCHEMA")
            SELECT engine_full, sorting_key, partition_key, primary_key, sampling_key
            FROM system.tables
            WHERE database = currentDatabase() AND name = #{quote(table_name.to_s)}
          SQL
          row ? dumpable_table_options(row) : {}
        end

        def change_column_comment(table_name, column_name, comment_or_changes)
          comment = extract_new_comment_value(comment_or_changes)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            COMMENT COLUMN #{quote_column_name(column_name)} #{quote(comment.to_s)}
          SQL
        end

        def change_table_comment(table_name, comment_or_changes)
          comment = extract_new_comment_value(comment_or_changes)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            MODIFY COMMENT #{quote(comment.to_s)}
          SQL
        end

        def table_comment(table_name)
          comment = select_value(<<~SQL.squish, "SCHEMA")
            SELECT comment FROM system.tables
            WHERE database = currentDatabase() AND name = #{quote(table_name.to_s)}
          SQL
          comment.presence
        end

        # Data-skipping indexes on existing tables; new parts index immediately,
        # existing parts only after MATERIALIZE INDEX (not issued here).
        def add_index(table_name, column_name, name: nil, if_not_exists: false, internal: false, **options)
          # The full abstract option list is accepted so cross-database migrations
          # port verbatim; only using:/granularity: affect the DDL. unique: is
          # unenforceable — ClickHouse has no unique indexes, so
          # index_exists?(unique: true) stays false.
          options.assert_valid_keys(valid_index_options)
          index_name = (name || index_name(table_name, column_name)).to_s
          validate_index_length!(table_name, index_name, internal)

          # bloom_filter serves equality lookups on any scalar type, so vanilla Rails
          # add_index calls port without edits; specialized types stay a using: away.
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            ADD INDEX #{"IF NOT EXISTS " if if_not_exists}#{quote_column_name(index_name)}
            #{index_expression(column_name)} TYPE #{options.fetch(:using, "bloom_filter")}
            GRANULARITY #{options.fetch(:granularity, 1)}
          SQL
        end

        def remove_index(table_name, column_name = nil, **options)
          return if options[:if_exists] && !index_exists?(table_name, column_name, **options)

          # Rails' resolver matches by columns, not derived name, so a custom-named
          # index is found by its columns and a name-shaped string is refused.
          name = index_name_for_remove(table_name, column_name, options.except(:if_exists))

          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            DROP INDEX #{quote_column_name(name)}
          SQL
        end

        private

        def valid_index_options
          super + [:granularity]
        end

        # Multi-column indexes need one tuple expression; a bare list is a syntax error.
        def index_expression(column_name)
          quoted = Array(column_name).map { |part| quote_column_name(part) }
          quoted.length == 1 ? quoted.first : "(#{quoted.join(", ")})"
        end

        def join_table_sorting_key(first_table, second_table, options)
          return "tuple()" if options.dig(:column_options, :null)

          references = [first_table, second_table].map { |table| "#{table.to_s.singularize}_id" }.sort
          "(#{references.join(", ")})"
        end

        def changed_column_sql_type(type, options)
          # Mirror new_column_definition: a datetime change without a precision key gets
          # Rails' default microseconds; an explicit precision: nil stays plain DateTime.
          options = { precision: 6, **options } if %i[datetime timestamp].include?(type.to_s.to_sym)
          sql_type = type_to_sql(type, **options.slice(:limit, :precision, :scale))
          sql_type = "Nullable(#{sql_type})" if options[:null]
          sql_type = "LowCardinality(#{sql_type})" if options[:low_cardinality]
          sql_type
        end

        # 26.6+ refuses Nullable(T) -> T without an in-statement DEFAULT (§2), so the
        # type's own default rides along when change_column narrows; the trailing
        # change_column_default(nil) removes it again. The stored-NULLs guard keeps
        # that DEFAULT from silently rewriting data during the conversion.
        def narrowing_placeholder_default(table_name, column_name, sql_type)
          column = column_for(table_name, column_name)
          return "" unless column&.null

          assert_no_stored_nulls(table_name, column_name)
          " DEFAULT defaultValueOfTypeName(#{quote(sql_type)})"
        end

        # REMOVE DEFAULT errors when none exists (code 36, probed 2026-07-14);
        # Rails treats clearing an absent default as a no-op, hence nil.
        def default_alteration_clause(table_name, column_name, default)
          if default.nil?
            column = columns(table_name).find { |candidate| candidate.name == column_name.to_s }
            return nil if column && column.default.nil? && column.default_function.nil?

            "REMOVE DEFAULT"
          else
            "DEFAULT #{default.respond_to?(:call) ? default.call : quote(default)}"
          end
        end

        # A bare MODIFY keeps the existing default (probed 2026-07-14) — deliberately
        # not change_column, whose replace-the-definition semantics would clear it.
        def widen_column_to_nullable(table_name, column_name, inner_type)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            MODIFY COLUMN #{quote_column_name(column_name)} Nullable(#{inner_type})
          SQL
        end

        # ClickHouse 26.6+ refuses Nullable(T) -> T without a DEFAULT clause in the
        # MODIFY COLUMN itself (BAD_ARGUMENTS, probed 2026-07-14). When the column has
        # no real default, the type's own default rides along as a placeholder and is
        # removed right after, restoring the pre-26.6 shape.
        def narrow_column(table_name, column_name, inner_type, column)
          default_expression =
            column.default_function || (column.default.nil? ? nil : quote(column.default))
          placeholder = default_expression.nil?
          default_expression ||= "defaultValueOfTypeName(#{quote(inner_type)})"
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            MODIFY COLUMN #{quote_column_name(column_name)} #{inner_type} DEFAULT #{default_expression}
          SQL
          change_column_default(table_name, column_name, nil) if placeholder
        end

        # The narrowing MODIFY's DEFAULT clause would rewrite stored NULLs silently;
        # Rails semantics say a narrow over NULLs without a backfill default is an error.
        # 25.8 serves a stale .null subcolumn for parts written before the column went
        # Nullable (probed 2026-07-14), so the count must read the real values.
        def assert_no_stored_nulls(table_name, column_name)
          nulls = select_value(<<~SQL.squish)
            SELECT count() FROM #{quote_table_name(table_name)}
            WHERE #{quote_column_name(column_name)} IS NULL
            SETTINGS optimize_functions_to_subcolumns = 0
          SQL
          return if nulls.to_i.zero?

          raise ActiveRecordError, "cannot make #{table_name}.#{column_name} non-nullable: " \
                                   "#{nulls} stored NULLs; pass a default to backfill them"
        end

        def backfill_nulls(table_name, column_name, default)
          with_request_settings(mutations_sync: 1) do
            execute(<<~SQL.squish)
              ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
              UPDATE #{quote_column_name(column_name)} = #{quote(default)}
              WHERE #{quote_column_name(column_name)} IS NULL
            SQL
          end
        end

        def drop_table_sql(...)
          "#{super}#{on_cluster_clause}"
        end

        def dictionary_columns(source, database)
          rows = select_all(<<~SQL.squish, "SCHEMA").to_a
            SELECT name, type FROM system.columns
            WHERE database = #{database ? quote(database.to_s) : "currentDatabase()"}
              AND table = #{quote(source.to_s)}
            ORDER BY position
          SQL
          raise ArgumentError, "dictionary source table #{source} has no columns" if rows.empty?

          rows.map { |row| "#{quote_column_name(row["name"])} #{row["type"]}" }.join(", ")
        end

        def dictionary_source(source, database)
          clauses = ["TABLE #{quote(source.to_s)}", "DB #{quote((database || @config[:database]).to_s)}"]
          clauses << "USER #{quote(@config[:username].to_s)}" if @config[:username]
          clauses << "PASSWORD #{quote(@config[:password].to_s)}" if @config[:password]
          clauses.join(" ")
        end

        def dictionary_layout(layout)
          raise ArgumentError, "unknown dictionary layout #{layout.inspect}" unless /\A[a-z_]+\z/.match?(layout.to_s)

          "#{layout.to_s.upcase}()"
        end

        def dictionary_lifetime(lifetime)
          range = lifetime.is_a?(Range) ? lifetime : (0..lifetime)
          "MIN #{Integer(range.begin)} MAX #{Integer(range.end)}"
        end

        def alter_partition(table_name, verb, partition_id, suffix: nil)
          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}
            #{verb} PARTITION ID #{quote(partition_id.to_s)}#{suffix}
          SQL
        end

        # DSL types like t.column :tags, "Array(String)" pass through verbatim once they
        # parse as a ClickHouse type; the server validates the family at DDL time.
        def clickhouse_type_verbatim(type)
          string = type.to_s
          raise ArgumentError, "unsupported column type for ClickHouse: #{type.inspect}" unless string.match?(/\A[A-Z]/)

          TypeParser.parse(string)
          string
        rescue TypeParser::Error
          raise ArgumentError, "unsupported column type for ClickHouse: #{type.inspect}"
        end

        # engine_full is "Engine(args) [PARTITION BY ...] [PRIMARY KEY ...] [ORDER BY ...]
        # [SAMPLE BY ...] [TTL ...] [SETTINGS ...]" — split on the clause keywords.
        ENGINE_FULL_CLAUSES = /\s+(PARTITION BY|PRIMARY KEY|ORDER BY|SAMPLE BY|TTL|SETTINGS)\s+/
        private_constant :ENGINE_FULL_CLAUSES

        def parse_engine_full(engine_full)
          engine, *clause_pairs = engine_full.to_s.split(ENGINE_FULL_CLAUSES)
          clauses = clause_pairs.each_slice(2).to_h { |keyword, expression| [keyword, expression] }
          { engine: engine.presence, ttl: clauses["TTL"], settings: clauses["SETTINGS"] }
        end

        def dumpable_table_options(row)
          clauses = parse_engine_full(row["engine_full"])
          {
            engine: clauses[:engine],
            partition: row["partition_key"].presence,
            primary_key: dumpable_primary_key(row),
            order: format_sorting_key(row["sorting_key"]),
            sample: row["sampling_key"].presence,
            ttl: clauses[:ttl],
            settings: dumpable_settings(clauses[:settings])
          }.compact
        end

        # The primary key defaults to the whole sorting key; only a narrower one is a
        # real PRIMARY KEY clause worth dumping.
        def dumpable_primary_key(row)
          format_sorting_key(row["primary_key"]) if row["primary_key"] != row["sorting_key"]
        end

        def format_sorting_key(sorting_key)
          return nil if sorting_key.blank?

          sorting_key.include?(",") ? "(#{sorting_key})" : sorting_key
        end

        # index_granularity = 8192 is the server default — dumping it is pure noise.
        def dumpable_settings(settings_clause)
          return nil if settings_clause.blank?

          settings = settings_clause.split(", ").to_h do |assignment|
            key, value = assignment.split(" = ", 2)
            [key.to_sym, value.match?(/\A-?\d+\z/) ? Integer(value) : value]
          end
          settings.delete(:index_granularity) if settings[:index_granularity] == 8192
          settings.presence
        end

        def internal_table_options(table_name, options)
          case table_name.to_s
          when ActiveRecord::Base.schema_migrations_table_name
            { engine: "ReplacingMergeTree", order: "version" }.merge(options)
          # No version column: Rails updates metadata entries via ALTER UPDATE, and
          # mutations cannot touch a ReplacingMergeTree version column (code 420,
          # probed 2026-07-14). Versionless keeps last-insert-wins for the create path.
          when ActiveRecord::Base.internal_metadata_table_name
            { engine: "ReplacingMergeTree", order: "key" }.merge(options)
          else
            options
          end
        end

        # DateTime64 tops out at nanoseconds; the server rejects scale 10+ with
        # ARGUMENT_OUT_OF_BOUND (code 69, probed live). Raise Rails' own wording at
        # DDL-build time instead, matching the bundled adapters' 0..6 checks.
        def datetime_to_sql(precision)
          return "DateTime('UTC')" if precision.nil?

          unless (0..9).cover?(precision.to_i)
            raise ArgumentError, "No timestamp type has precision of #{precision}. " \
                                 "The allowed range of precision is from 0 to 9"
          end

          "DateTime64(#{precision}, 'UTC')"
        end

        # Bare precision means scale 0 (SQL convention; Decimal(2, 10) is
        # ARGUMENT_OUT_OF_BOUND — scale may not exceed precision). Bare scale is the
        # same ArgumentError Rails' other adapters raise. No bounds at all keeps the
        # wide Decimal(38, 10) default.
        def decimal_to_sql(precision, scale)
          if precision
            "Decimal(#{precision}, #{scale || 0})"
          elsif scale
            raise ArgumentError, "Error adding decimal column: precision cannot be empty if scale is specified"
          else
            "Decimal(38, 10)"
          end
        end

        def integer_to_sql(limit)
          case limit
          when nil, 3, 4 then "Int32"
          when 1 then "Int8"
          when 2 then "Int16"
          when 5..8 then "Int64"
          when 9..16 then "Int128"
          when 17..32 then "Int256"
          else raise ArgumentError, "no ClickHouse integer type has byte size #{limit}"
          end
        end

        def data_source_sql(name = nil, type: nil)
          conditions = ["database = currentDatabase()"]
          conditions << "name = #{quote(name.to_s)}" if name
          case type
          when "BASE TABLE" then conditions << "engine NOT IN (#{quoted_non_table_engines}, 'Dictionary')"
          when "VIEW" then conditions << "engine IN (#{quoted_non_table_engines})"
          end
          "SELECT name FROM system.tables WHERE #{conditions.join(" AND ")} ORDER BY name"
        end

        def quoted_non_table_engines
          NON_TABLE_ENGINES.map { |engine| quote(engine) }.join(", ")
        end

        def column_definitions(table_name)
          select_all(<<~SQL.squish, "SCHEMA").to_a
            SELECT name, type, default_kind, default_expression, comment, compression_codec
            FROM system.columns
            WHERE database = currentDatabase() AND table = #{quote(table_name.to_s)}
            ORDER BY position
          SQL
        end

        def new_column_from_field(_table_name, field, _definitions)
          sql_type = field["type"]
          cast_type = Types.active_record_cast_type(sql_type)
          default_value, default_function = extract_default(field)

          Column.new(
            field["name"],
            cast_type,
            default_value,
            fetch_type_metadata(sql_type, cast_type),
            sql_type.start_with?("Nullable("),
            default_function,
            comment: field["comment"].presence,
            **clickhouse_column_extras(field)
          )
        end

        def clickhouse_column_extras(field)
          {
            codec: field["compression_codec"].delete_prefix("CODEC(").delete_suffix(")").presence,
            computed_kind: field["default_kind"].presence_in(%w[MATERIALIZED ALIAS])&.downcase,
            computed_expression: field["default_expression"].presence
          }
        end

        def extract_default(field)
          return [nil, nil] unless field["default_kind"] == "DEFAULT"

          expression = field["default_expression"]
          case expression
          when /\A'(.*)'\z/m then [unescape_string_literal(Regexp.last_match(1)), nil]
          when /\A-?\d+(?:\.\d+)?\z/, "true", "false" then [expression, nil]
          else [nil, expression]
          end
        end

        # The server renders control characters as escape sequences in
        # default_expression ('foo\nbar' arrives as backslash-n, probed 2026-07-14).
        STRING_LITERAL_ESCAPES = {
          "0" => "\0", "a" => "\a", "b" => "\b", "f" => "\f",
          "n" => "\n", "r" => "\r", "t" => "\t", "v" => "\v"
        }.freeze
        private_constant :STRING_LITERAL_ESCAPES

        def unescape_string_literal(contents)
          contents.gsub(/\\(.)|''/) do
            escaped = Regexp.last_match(1)
            escaped ? STRING_LITERAL_ESCAPES.fetch(escaped, escaped) : "'"
          end
        end

        def fetch_type_metadata(sql_type, cast_type = Types.active_record_cast_type(sql_type))
          SqlTypeMetadata.new(
            sql_type: sql_type,
            type: cast_type.type,
            limit: cast_type.limit,
            precision: cast_type.precision,
            scale: cast_type.scale
          )
        end

        def schema_creation
          SchemaCreation.new(self)
        end

        def create_table_definition(name, **)
          TableDefinition.new(self, name, **)
        end
      end
    end
  end
end
