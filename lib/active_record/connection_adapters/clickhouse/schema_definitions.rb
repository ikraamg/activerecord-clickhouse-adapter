# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      class TableDefinition < ConnectionAdapters::TableDefinition
        attr_reader :engine, :order, :partition, :ttl, :table_settings

        def initialize(conn, name, engine: "MergeTree", order: nil, partition: nil, ttl: nil,
                       settings: nil, **)
          @engine = engine
          @order = order
          @partition = partition
          @ttl = ttl
          @table_settings = settings
          super(conn, name, **)
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
        def index_in_create(_table_name, column_name, options)
          expression = Array(column_name).join(", ")
          type = options.fetch(:using) { raise ArgumentError, "ClickHouse indexes need using: (e.g. \"bloom_filter\")" }
          "INDEX #{quote_column_name(options.fetch(:name))} #{expression} " \
            "TYPE #{type} GRANULARITY #{options.fetch(:granularity, 1)}"
        end

        def add_column_options!(sql, options)
          if options_include_default?(options)
            default = options[:default]
            sql << " DEFAULT #{default.is_a?(Proc) ? default.call : @conn.quote(default)}"
          end
          sql
        end

        def add_table_options!(create_sql, o)
          if o.engine.include?("MergeTree") && o.order.nil?
            raise ArgumentError, "#{o.engine} tables require order: (the sorting key); use order: \"tuple()\" for none"
          end

          create_sql << " ENGINE = #{o.engine}"
          create_sql << " PARTITION BY #{o.partition}" if o.partition
          create_sql << " ORDER BY #{o.order}" if o.order
          create_sql << " TTL #{o.ttl}" if o.ttl
          create_sql << " SETTINGS #{format_settings(o.table_settings)}" if o.table_settings.present?
          create_sql
        end

        def format_settings(settings)
          settings.map { |key, value| "#{key} = #{value}" }.join(", ")
        end
      end
    end
  end
end
