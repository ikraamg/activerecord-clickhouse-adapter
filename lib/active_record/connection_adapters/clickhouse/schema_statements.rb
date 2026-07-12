# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      module SchemaStatements
        NON_TABLE_ENGINES = %w[View MaterializedView LiveView].freeze

        # ClickHouse has no autoincrement; tables default to no id column and the
        # sorting key acts as the primary key.
        def create_table(table_name, id: false, **options, &block)
          options = internal_table_options(table_name, options)
          super
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
          super + %i[engine order partition ttl settings]
        end

        def valid_column_definition_options
          super + [:low_cardinality]
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
            SELECT engine_full, sorting_key, partition_key FROM system.tables
            WHERE database = currentDatabase() AND name = #{quote(table_name.to_s)}
          SQL
          return {} unless row

          clauses = parse_engine_full(row["engine_full"])
          {
            engine: clauses[:engine],
            partition: row["partition_key"].presence,
            order: format_sorting_key(row["sorting_key"]),
            ttl: clauses[:ttl],
            settings: dumpable_settings(clauses[:settings])
          }.compact
        end

        private

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
            SELECT name, type, default_kind, default_expression, comment
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
            comment: field["comment"].presence
          )
        end

        def extract_default(field)
          return [nil, nil] unless field["default_kind"] == "DEFAULT"

          expression = field["default_expression"]
          case expression
          when /\A'(.*)'\z/m then [unescape_string_literal(Regexp.last_match(1)), nil]
          when /\A-?\d+(?:\.\d+)?\z/ then [expression, nil]
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
