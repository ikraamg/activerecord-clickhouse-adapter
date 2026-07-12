# frozen_string_literal: true

require "date"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      module DatabaseStatements
        READ_QUERY = ActiveRecord::ConnectionAdapters::AbstractAdapter.build_read_query_regexp(
          :select, :show, :describe, :desc, :exists, :explain, :check, :with
        )
        private_constant :READ_QUERY

        def write_query?(sql) # :nodoc:
          !READ_QUERY.match?(sql)
        rescue ArgumentError # non-UTF8 SQL, mirror the built-in adapters
          !READ_QUERY.match?(sql.b)
        end

        private

        def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch:) # rubocop:disable Lint/UnusedMethodArgument
          sql, params = materialize_query_params(sql, binds, type_casted_binds)
          result = raw_connection.execute(sql, params: params)
          verified!
          notification_payload[:row_count] = result.rows.size if notification_payload
          result
        end

        def cast_result(raw_result)
          if raw_result.columns.empty?
            ActiveRecord::Result.empty(affected_rows: raw_result.written_rows)
          else
            casters = raw_result.types.map { |type_string| Types.caster_for(type_string) }
            rows = raw_result.rows.map do |row|
              row.each_with_index.map { |value, index| casters.fetch(index).cast(value) }
            end
            ActiveRecord::Result.new(raw_result.columns, rows)
          end
        end

        def affected_rows(raw_result) = raw_result.written_rows

        # Replace `?` placeholders with ClickHouse `{pN:Type}` and collect HTTP param values.
        def materialize_query_params(sql, binds, type_casted_binds) # rubocop:disable Metrics/MethodLength
          return [sql, {}] if binds.blank?

          params = {}
          index = -1
          rewritten = sql.gsub("?") do
            index += 1
            name = "p#{index}"
            params[name] = format_query_param(type_casted_binds.fetch(index))
            "{#{name}:#{clickhouse_bind_type(binds.fetch(index), type_casted_binds.fetch(index))}}"
          end
          raise ArgumentError, "wrong number of bind parameters" unless index == binds.length - 1

          [rewritten, params]
        end

        def format_query_param(value)
          case value
          when Time, DateTime then value.utc.strftime("%Y-%m-%d %H:%M:%S")
          when Date then value.strftime("%Y-%m-%d")
          when true, false then value
          else value.to_s
          end
        end

        def clickhouse_bind_type(bind, casted_value) # rubocop:disable Metrics/CyclomaticComplexity
          type = bind.type if bind.respond_to?(:type)
          case type
          when ActiveRecord::Type::Boolean then "Bool"
          when ActiveRecord::Type::Integer then casted_value.negative? ? "Int64" : "UInt64"
          when ActiveRecord::Type::Float then "Float64"
          when ActiveRecord::Type::Decimal, ActiveRecord::Type::String, ActiveRecord::Type::Text then "String"
          when ActiveRecord::Type::Date then "Date"
          when ActiveRecord::Type::DateTime then "DateTime64(6)"
          else inferred_bind_type(casted_value)
          end
        end

        def inferred_bind_type(casted_value)
          case casted_value
          when Integer then casted_value.negative? ? "Int64" : "UInt64"
          when Float then "Float64"
          when true, false then "Bool"
          when Date then "Date"
          when Time, DateTime then "DateTime64(6)"
          else "String"
          end
        end
      end
    end
  end
end
