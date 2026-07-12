# frozen_string_literal: true

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

        def perform_query(raw_connection, sql, _binds, _type_casted_binds, prepare:, notification_payload:, batch:) # rubocop:disable Lint/UnusedMethodArgument
          result = raw_connection.execute(sql)
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
      end
    end
  end
end
