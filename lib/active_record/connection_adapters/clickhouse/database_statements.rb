# frozen_string_literal: true

require "date"
require "securerandom"
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

        # No autoincrement and no INSERT ... RETURNING: primary keys are generated
        # client-side before the INSERT (the Oracle-adapter prefetch seam), but only
        # for tables whose sorting key is a single generatable column — Rails'
        # prefetch path cannot handle composite primary keys.
        def prefetch_primary_key?(table_name = nil)
          !table_name.nil? && !generatable_primary_key(table_name).nil?
        end

        # The "sequence" is the pk column itself; encode table.column so
        # next_sequence_value can check it against the sorting key. Composite keys
        # have no single column to generate.
        def default_sequence_name(table_name, column_name)
          return nil if column_name.is_a?(Array)

          "#{table_name}.#{column_name}"
        end

        def next_sequence_value(sequence_name)
          table_name, column_name = sequence_name.to_s.split(".", 2)
          generatable_column, sql_type = table_name && generatable_primary_key(table_name)
          raise_ungeneratable_primary_key(sequence_name) unless generatable_column == column_name

          sql_type == "UUID" ? generate_uuid_v7 : generate_time_ordered_id
        end

        # No INSERT ... RETURNING in ClickHouse: the prefetched client-side id is the
        # only post-insert-knowable value, so surface it as the returning row that
        # _create_record writes back onto the record. The signature is Rails'
        # DatabaseStatements#insert contract.
        def insert(arel, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [], returning: nil) # rubocop:disable Metrics/ParameterLists
          inserted_id = super(arel, name, pk, id_value, sequence_name, binds, returning: nil)
          returning.nil? ? inserted_id : [inserted_id]
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

        GENERATABLE_ID_TYPES = /\A(?:U?Int(?:64|128|256)|UUID)\z/
        private_constant :GENERATABLE_ID_TYPES

        SORTING_KEY_COLUMN_SQL = <<~SQL.squish
          SELECT columns.name AS name, columns.type AS type
          FROM system.tables AS tables
          INNER JOIN system.columns AS columns
            ON columns.database = tables.database
            AND columns.table = tables.name
            AND columns.name = tables.sorting_key
          WHERE tables.database = currentDatabase() AND tables.name = %s
        SQL
        private_constant :SORTING_KEY_COLUMN_SQL

        # [column_name, sql_type] when the table's sorting key is one column typed
        # widely enough to hold a generated id; nil otherwise (composite keys,
        # expression keys, narrow integers, strings).
        def generatable_primary_key(table_name)
          row = select_one(format(SORTING_KEY_COLUMN_SQL, quote(table_name.to_s)), "SCHEMA")
          return nil unless row && GENERATABLE_ID_TYPES.match?(row["type"])

          [row["name"], row["type"]]
        end

        RANDOM_ID_BITS = 22
        private_constant :RANDOM_ID_BITS

        # 41 bits of Unix milliseconds + 22 random bits = 63 bits: time-ordered like
        # UUIDv7 and safely inside signed Int64 until the year 4707.
        def generate_time_ordered_id
          milliseconds = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
          (milliseconds << RANDOM_ID_BITS) | SecureRandom.random_number(1 << RANDOM_ID_BITS)
        end

        # SecureRandom.uuid_v7 needs Ruby >= 3.3; build the same layout on 3.2:
        # 48-bit millisecond timestamp, version nibble 7, variant bits 10.
        def generate_uuid_v7
          return SecureRandom.uuid_v7 if SecureRandom.respond_to?(:uuid_v7)

          milliseconds = Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
          hex = format("%<ms>012x", ms: milliseconds) + SecureRandom.hex(10)
          hex[12] = "7"
          hex[16] = %w[8 9 a b].fetch(hex[16].to_i(16) & 0x3)
          hex.insert(20, "-").insert(16, "-").insert(12, "-").insert(8, "-")
        end

        def raise_ungeneratable_primary_key(sequence_name)
          raise ActiveRecordError, "cannot generate a primary key for #{sequence_name.inspect}: " \
                                   "the table's sorting key must be that single column, typed " \
                                   "at least 64 bits wide or UUID; assign ids explicitly instead"
        end

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
