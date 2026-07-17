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

        # Materialized views and dictionaries dump after every table so their sources
        # exist on load (dictionaries bind lazily, but keep the order intuitive).
        def tables(stream)
          super
          materialized_views(stream)
          dictionaries(stream)
        end

        DICTIONARIES_SQL = <<~SQL.squish
          SELECT name, create_table_query FROM system.tables
          WHERE database = currentDatabase() AND engine = 'Dictionary'
          ORDER BY name
        SQL
        private_constant :DICTIONARIES_SQL

        def dictionaries(stream)
          dumpable = @connection.select_all(DICTIONARIES_SQL, "SCHEMA").reject { |row| ignored?(row["name"]) }
          dumpable.each_with_index do |dictionary, index|
            stream.puts if index.zero?
            stream.puts dictionary_statement(dictionary)
          end
        end

        # create_dictionary re-infers columns and re-injects credentials at load time,
        # so only the identity kwargs are parsed back out of the stored DDL.
        def dictionary_statement(dictionary)
          kwargs = dictionary_kwargs(dictionary["create_table_query"])
          rendered = kwargs.map { |keyword, value| "#{keyword}: #{value}" }
          "  create_dictionary #{dictionary["name"].inspect}, #{rendered.join(", ")}"
        end

        def dictionary_kwargs(ddl)
          database = ddl[/\bDB '([^']+)'/, 1]
          {
            source: ddl[/\bTABLE '([^']+)'/, 1].inspect,
            database: (database.inspect if database && database != current_database),
            primary_key: ddl[/\bPRIMARY KEY ([^\s(]+)/, 1].inspect,
            layout: ddl[/\bLAYOUT\((\w+)\(/, 1].downcase.to_sym.inspect,
            lifetime: "#{ddl[/\bLIFETIME\(MIN (\d+)/, 1].to_i}..#{ddl[/\bMAX (\d+)\)/, 1].to_i}"
          }.compact
        end

        # Projections dump right after their table as add_projection calls, parsed back
        # out of the stored query text (SELECT ... [GROUP BY ...] [ORDER BY ...]).
        def table(table, stream)
          super
          projections(table).each do |row|
            stream.puts("  #{projection_statement(table, row)}")
            stream.puts
          end
        end

        PROJECTIONS_SQL = <<~SQL.squish
          SELECT name, query FROM system.projections
          WHERE database = currentDatabase() AND table = %s ORDER BY name
        SQL
        private_constant :PROJECTIONS_SQL

        def projections(table)
          @connection.select_all(format(PROJECTIONS_SQL, @connection.quote(table)), "SCHEMA").to_a
        end

        def projection_statement(table, row)
          query = row["query"]
          parts = {
            select: query[/\ASELECT\s+(.*?)(?:\s+GROUP BY\s|\s+ORDER BY\s|\z)/m, 1],
            group: query[/\sGROUP BY\s+(.*?)(?:\s+ORDER BY\s|\z)/m, 1],
            order: query[/\sORDER BY\s+(.*)\z/m, 1]
          }.compact
          arguments = parts.map { |keyword, expression| "#{keyword}: #{expression.inspect}" }
          "add_projection #{table.inspect}, #{row["name"].inspect}, #{arguments.join(", ")}"
        end

        MATERIALIZED_VIEW_SQL = <<~SQL.squish
          SELECT name, as_select, create_table_query FROM system.tables
          WHERE database = currentDatabase() AND engine = 'MaterializedView'
          ORDER BY name
        SQL
        private_constant :MATERIALIZED_VIEW_SQL

        def materialized_views(stream)
          dumpable = @connection.select_all(MATERIALIZED_VIEW_SQL, "SCHEMA").reject { |view| ignored?(view["name"]) }
          dumpable.each_with_index do |view, index|
            stream.puts if index.zero?
            stream.puts materialized_view_statement(view)
          end
        end

        # The server database-qualifies every identifier it stores; strip the current
        # database so the dump loads into any target database.
        def materialized_view_statement(view)
          target = view["create_table_query"][/\bTO\s+(\S+)/, 1]
          select = strip_database_qualifier(view["as_select"])
          "  create_materialized_view #{view["name"].inspect}, " \
            "to: #{strip_database_qualifier(target).inspect}, as: #{select.inspect}"
        end

        def strip_database_qualifier(sql)
          database = Regexp.escape(current_database)
          sql.gsub(/(?:`#{database}`|#{database})\./, "")
        end

        def current_database
          @current_database ||= @connection.select_value("SELECT currentDatabase()", "SCHEMA")
        end

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
          spec.merge!(clickhouse_column_options(column))
        end

        def clickhouse_column_options(column)
          spec = {}
          spec[column.computed_kind.to_sym] = column.computed_expression.inspect if column.computed_kind
          spec[:codec] = column.codec.inspect if column.codec
          spec
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

        # Hash#inspect renders {:key=>value} before Ruby 3.4; emit the modern literal
        # so the settings: option dumps identically on every supported Ruby.
        def format_options(options)
          options.map { |key, value| "#{key}: #{format_option_value(value)}" }.join(", ")
        end

        def format_option_value(value)
          return value.inspect unless value.is_a?(Hash)

          "{#{value.map { |key, entry| "#{key}: #{entry.inspect}" }.join(", ")}}"
        end
      end
    end
  end
end
