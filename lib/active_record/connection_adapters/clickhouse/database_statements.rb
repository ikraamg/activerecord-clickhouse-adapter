# frozen_string_literal: true

require "date"
require "strscan"

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

        EXPLAIN_VARIANTS = {
          plan: "EXPLAIN", pipeline: "EXPLAIN PIPELINE",
          estimate: "EXPLAIN ESTIMATE", indexes: "EXPLAIN indexes = 1"
        }.freeze
        private_constant :EXPLAIN_VARIANTS

        def explain(arel, binds = [], options = []) # :nodoc:
          sql = "#{build_explain_clause(options)} #{to_sql(arel, binds)}"
          result = internal_exec_query(sql, "EXPLAIN", binds)
          ([result.columns.join("\t")] + result.rows.map { |row| row.join("\t") }).join("\n")
        end

        def build_explain_clause(options = [])
          variant = options.first || :plan
          EXPLAIN_VARIANTS.fetch(variant.to_sym) do
            raise ArgumentError, "unknown EXPLAIN variant #{variant.inspect}; use #{EXPLAIN_VARIANTS.keys.inspect}"
          end
        end

        # The abstract version wraps bare DELETEs in a transaction; ClickHouse has
        # neither, so fixtures load as TRUNCATE + batched INSERTs.
        def insert_fixtures_set(fixture_set, tables_to_delete = [])
          statements = tables_to_delete.map { |table| build_truncate_statement(table) }
          statements += fixture_set.filter_map do |table_name, fixtures|
            build_fixture_sql(fixtures, table_name) unless fixtures.empty?
          end
          statements.each { |statement| execute(statement, "Fixtures Load") }
        end

        private

        def perform_query(raw_connection, sql, binds, type_casted_binds, prepare:, notification_payload:, batch:) # rubocop:disable Lint/UnusedMethodArgument
          sql, params = materialize_query_params(sql, binds, type_casted_binds)
          result = raw_connection.execute(sql, params: params)
          verified!
          if notification_payload
            notification_payload[:row_count] = result.rows.size
            notification_payload[:clickhouse] = result.stats
          end
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

        STRING_LITERAL = /'(?:\\.|''|[^'])*'/m
        BACKTICK_IDENTIFIER = /`(?:\\.|``|[^`])*`/m
        private_constant :STRING_LITERAL, :BACKTICK_IDENTIFIER

        # Replace `?` placeholders with ClickHouse `{pN:Type}` and collect HTTP param
        # values, skipping `?` inside string literals and backtick identifiers.
        def materialize_query_params(sql, binds, type_casted_binds) # rubocop:disable Metrics/MethodLength
          return [sql, {}] if binds.blank?

          scanner = StringScanner.new(sql)
          rewritten = +""
          params = {}
          until scanner.eos?
            rewritten << if scanner.skip("?")
                           bind_placeholder(params, binds, type_casted_binds)
                         else
                           scan_non_placeholder_fragment(scanner)
                         end
          end
          verify_bind_count(params, binds)
          [rewritten, params]
        end

        def verify_bind_count(params, binds)
          return if params.length == binds.length

          raise ArgumentError, "wrong number of binds (#{params.length} for #{binds.length})"
        end

        def scan_non_placeholder_fragment(scanner)
          scanner.scan(STRING_LITERAL) || scanner.scan(BACKTICK_IDENTIFIER) || scanner.scan(/[^?'`]+/) || scanner.getch
        end

        def bind_placeholder(params, binds, type_casted_binds)
          index = params.length
          raise ArgumentError, "more ? placeholders than binds (#{binds.length})" if index >= binds.length

          name = "p#{index}"
          params[name] = format_query_param(type_casted_binds.fetch(index))
          "{#{name}:#{clickhouse_bind_type(binds.fetch(index), type_casted_binds.fetch(index))}}"
        end

        # The server reads String params in its escaped format: raw newlines/tabs raise
        # BAD_QUERY_PARAMETER and a literal backslash-n would silently become a newline.
        PARAM_ESCAPES = { "\\" => "\\\\", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r", "\0" => "\\0" }.freeze
        PARAM_ESCAPE_PATTERN = /[\\\n\t\r\0]/
        private_constant :PARAM_ESCAPES, :PARAM_ESCAPE_PATTERN

        # Adapter-level type_cast already stringifies Date/Time (with subseconds) and
        # BigDecimal before values reach here.
        def format_query_param(value)
          case value
          when true, false then value
          else
            string = value.to_s
            string.match?(PARAM_ESCAPE_PATTERN) ? string.gsub(PARAM_ESCAPE_PATTERN, PARAM_ESCAPES) : string
          end
        end

        # Date/Time binds arrive as pre-formatted strings (adapter type_cast), so only the
        # declared AR type can recover them; everything else is inferable from the value.
        def clickhouse_bind_type(bind, casted_value)
          type = bind.type if bind.respond_to?(:type)
          case type
          when ActiveRecord::Type::Date then "Date"
          when ActiveRecord::Type::DateTime, ActiveRecord::Type::Time then "DateTime64(6)"
          else inferred_bind_type(casted_value)
          end
        end

        def inferred_bind_type(casted_value)
          case casted_value
          when Integer then clickhouse_integer_type(casted_value)
          when Float then "Float64"
          when true, false then "Bool"
          when Date then "Date"
          when Time, DateTime then "DateTime64(6)"
          else "String"
          end
        end

        INTEGER_TYPE_BY_RANGE = {
          "Int64" => -(2**63)...(2**63),
          "UInt64" => 0...(2**64),
          "Int128" => -(2**127)...(2**127),
          "UInt128" => 0...(2**128),
          "Int256" => -(2**255)...(2**255),
          "UInt256" => 0...(2**256)
        }.freeze
        private_constant :INTEGER_TYPE_BY_RANGE

        # Sized by magnitude — a too-small type makes the server wrap the value mod 2^N.
        def clickhouse_integer_type(value)
          type, = INTEGER_TYPE_BY_RANGE.find { |_, range| range.cover?(value) }
          type || raise(ActiveModel::RangeError, "#{value} is out of range for ClickHouse integer types")
        end
      end
    end
  end
end
