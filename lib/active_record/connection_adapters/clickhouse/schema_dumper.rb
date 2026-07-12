# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Dumps columns so the schema round-trips through this adapter's DSL: AR-native
      # types only when type_to_sql regenerates the exact server type, everything else
      # as a verbatim ClickHouse type string; Nullable/LowCardinality become column
      # options because absence of null: means NOT NULL here, unlike core Rails.
      class SchemaDumper < ConnectionAdapters::SchemaDumper
        private

        def column_spec(column)
          inner_type, wrappers = unwrap_column_type(column.sql_type)
          type = schema_type(column)

          if regenerates_exactly?(type, inner_type, column)
            spec = prepare_column_options(column)
            spec[:low_cardinality] = "true" if wrappers.include?(:low_cardinality)
            [type, spec]
          else
            [column.sql_type, verbatim_column_options(column)]
          end
        end

        def prepare_column_options(column)
          spec = super
          spec.delete(:null)
          spec[:null] = "true" if column.null
          spec
        end

        # Rails omits precision 6 as the datetime default, but this adapter's default is
        # DateTime64(3) — always dump the real precision.
        def schema_precision(column)
          column.precision&.inspect
        end

        WRAPPER_TYPES = { /\ALowCardinality\((.*)\)\z/m => :low_cardinality, /\ANullable\((.*)\)\z/m => :null }.freeze
        private_constant :WRAPPER_TYPES

        def unwrap_column_type(sql_type)
          wrappers = []
          inner = sql_type
          while (wrapper = WRAPPER_TYPES.find { |pattern, _| pattern.match?(inner) })
            wrappers << wrapper.last
            inner = inner.match(wrapper.first)[1]
          end
          [inner, wrappers]
        end

        def regenerates_exactly?(type, inner_type, column)
          return false unless type

          regenerated = @connection.type_to_sql(
            type, limit: column.limit, precision: column.precision, scale: column.scale
          )
          regenerated == inner_type
        rescue ArgumentError
          false
        end

        def verbatim_column_options(column)
          spec = {}
          spec[:default] = schema_default(column)
          spec[:comment] = column.comment.inspect if column.comment.present?
          spec.compact
        end

        def index_parts(index)
          super + ["granularity: #{index.granularity}"]
        end
      end
    end
  end
end
