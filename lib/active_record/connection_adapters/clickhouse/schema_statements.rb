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

        def rename_table(table_name, new_name, **)
          clear_generatable_primary_key_cache
          execute("RENAME TABLE #{quote_table_name(table_name)} TO #{quote_table_name(new_name)}#{on_cluster_clause}")
        end

        def remove_column(table_name, column_name, type = nil, **options)
          return if options[:if_exists] == true && !column_exists?(table_name, column_name)

          execute(<<~SQL.squish)
            ALTER TABLE #{quote_table_name(table_name)}#{on_cluster_clause}
            #{remove_column_for_alter(table_name, column_name, type, **options)}
          SQL
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
        def create_dictionary(name, source:, primary_key:, layout: :flat, lifetime: 300)
          execute(<<~SQL.squish)
            CREATE DICTIONARY #{quote_table_name(name)} (#{dictionary_columns(source)})
            PRIMARY KEY #{quote_column_name(primary_key)}
            SOURCE(CLICKHOUSE(#{dictionary_source(source)}))
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
        # drops it (probed 2026-07-13).
        def change_column_default(table_name, column_name, default_or_changes)
          default = extract_new_default_value(default_or_changes)
          rendered = default.respond_to?(:call) ? default.call : quote(default)
          alteration = default.nil? ? "REMOVE DEFAULT" : "DEFAULT #{rendered}"
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
              columns: [row["expr"]], using: row["type_full"], granularity: row["granularity"]
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
          when "string", "text" then "String"
          when "float" then "Float64"
          when "decimal", "numeric" then "Decimal(#{precision || 38}, #{scale || 10})"
          when "datetime", "timestamp" then "DateTime64(#{precision || 3}, 'UTC')"
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

        private

        def drop_table_sql(...)
          "#{super}#{on_cluster_clause}"
        end

        def dictionary_columns(source)
          columns(source).map { |column| "#{quote_column_name(column.name)} #{column.sql_type}" }.join(", ")
        end

        def dictionary_source(source)
          clauses = ["TABLE #{quote(source.to_s)}", "DB #{quote(@config[:database].to_s)}"]
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
          when ActiveRecord::Base.internal_metadata_table_name
            { engine: "ReplacingMergeTree(updated_at)", order: "key" }.merge(options)
          else
            options
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
          when "BASE TABLE" then conditions << "engine NOT IN (#{quoted_non_table_engines})"
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

        def unescape_string_literal(contents)
          contents.gsub(/\\(.)|''/) { Regexp.last_match(1) || "'" }
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
