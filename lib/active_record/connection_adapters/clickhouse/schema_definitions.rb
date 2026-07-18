# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      class TableDefinition < ConnectionAdapters::TableDefinition
        attr_reader :engine, :order, :partition, :ttl, :table_settings, :primary_key_clause, :sample

        def initialize(conn, name, engine: "MergeTree", order: nil, partition: nil, ttl: nil,
                       settings: nil, primary_key_clause: nil, sample: nil, **)
          @engine = engine
          @order = order
          @partition = partition
          @ttl = ttl
          @table_settings = settings
          @primary_key_clause = primary_key_clause
          @sample = sample
          super(conn, name, **)
        end
      end

      # Carries the ClickHouse-only column metadata the dumper needs: compression codec
      # and MATERIALIZED/ALIAS server-computed expressions.
      class Column < ConnectionAdapters::Column
        attr_reader :codec, :computed_kind, :computed_expression

        def initialize(*, codec: nil, computed_kind: nil, computed_expression: nil, **)
          @codec = codec
          @computed_kind = computed_kind
          @computed_expression = computed_expression
          super(*, **)
        end
      end

      # A ClickHouse data-skipping index: `using` is the full index type expression
      # ("bloom_filter", "set(100)", ...) and granularity is index blocks per granule.
      class IndexDefinition < ConnectionAdapters::IndexDefinition
        attr_reader :granularity

        def initialize(table, name, columns:, using:, granularity:)
          @granularity = granularity
          super(table, name, false, columns, using: using)
        end
      end

      class SchemaCreation < ConnectionAdapters::SchemaCreation
        private

        def visit_TableDefinition(o)
          stamp_on_cluster(super, o.name)
        end

        def visit_AlterTable(o)
          stamp_on_cluster(super, o.name)
        end

        # ON CLUSTER renders directly after the table name; the first mention is the
        # one following CREATE/ALTER TABLE.
        def stamp_on_cluster(sql, table_name)
          clause = @conn.on_cluster_clause
          return sql if clause.empty?

          quoted = quote_table_name(table_name)
          sql.sub("TABLE #{quoted} ", "TABLE #{quoted}#{clause} ")
        end

        # ClickHouse nullability lives in the type (Nullable/LowCardinality wrappers),
        # not in NOT NULL constraints, and MergeTree requires an ORDER BY clause.
        def visit_ColumnDefinition(o)
          o.sql_type = type_to_sql(o.type, **o.options)
          column_sql = "#{quote_column_name(o.name)} #{wrapped_sql_type(o)}"
          add_column_options!(column_sql, column_options(o))
          column_sql
        end

        def wrapped_sql_type(o)
          sql_type = o.sql_type
          sql_type = "Nullable(#{sql_type})" if o.options[:null]
          sql_type = "LowCardinality(#{sql_type})" if o.options[:low_cardinality]
          sql_type
        end

        def visit_AddColumnDefinition(o)
          "ADD COLUMN #{accept(o.column)}"
        end

        # Data-skipping indexes are part of CREATE TABLE (supports_indexes_in_create?);
        # the expression passes through verbatim — it may be a function of columns.
        def index_in_create(table_name, column_name, options)
          columns = Array(column_name)
          expression = columns.length == 1 ? columns.first.to_s : "(#{columns.join(", ")})"
          name = options.fetch(:name) { @conn.index_name(table_name, column_name) }
          # Same portability default as add_index: bloom_filter unless told otherwise.
          "INDEX #{quote_column_name(name)} #{expression} " \
            "TYPE #{options.fetch(:using, "bloom_filter")} GRANULARITY #{options.fetch(:granularity, 1)}"
        end

        # DEFAULT / MATERIALIZED / ALIAS are mutually exclusive ways for a column to get
        # its value; CODEC composes with any of them.
        def add_column_options!(sql, options)
          sql << column_value_clause(options).to_s
          sql << " CODEC(#{options[:codec]})" if options[:codec]
          sql
        end

        def column_value_clause(options)
          clauses = []
          if options_include_default?(options)
            default = options[:default]
            clauses << " DEFAULT #{default.is_a?(Proc) ? default.call : @conn.quote(default)}"
          end
          clauses << " MATERIALIZED #{options[:materialized]}" if options[:materialized]
          clauses << " ALIAS #{options[:alias]}" if options[:alias]
          raise ArgumentError, "materialized:, alias: and default: are mutually exclusive" if clauses.many?

          clauses.first
        end

        def add_table_options!(create_sql, o)
          # PRIMARY KEY alone is enough: the server infers ORDER BY from it (probed live).
          if o.engine.include?("MergeTree") && o.order.nil? && o.primary_key_clause.nil?
            raise ArgumentError, "#{o.engine} tables require order: (the sorting key); use order: \"tuple()\" for none"
          end

          create_sql << " ENGINE = #{o.engine}"
          table_clauses(o).each { |keyword, expression| create_sql << " #{keyword} #{expression}" if expression }
          create_sql
        end

        def table_clauses(o)
          {
            "PARTITION BY" => o.partition,
            "PRIMARY KEY" => o.primary_key_clause,
            "ORDER BY" => o.order,
            "SAMPLE BY" => o.sample,
            "TTL" => o.ttl,
            "SETTINGS" => o.table_settings.present? ? format_settings(o.table_settings) : nil
          }
        end

        def format_settings(settings)
          settings.map { |key, value| "#{key} = #{value}" }.join(", ")
        end
      end
    end
  end
end
