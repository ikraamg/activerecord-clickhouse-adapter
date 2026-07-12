# frozen_string_literal: true

require "active_record/connection_adapters/clickhouse/http_connection"

module ActiveRecord
  module Tasks
    # db:create/db:drop/db:purge and structure dump/load for ClickHouse. Database-level
    # DDL runs over a raw HTTP connection without a database selected, since the
    # configured database may not exist yet.
    class ClickHouseDatabaseTasks < AbstractTasks
      DATABASE_ALREADY_EXISTS_CODE = 82
      UNKNOWN_DATABASE_CODE = 81

      def create
        server_execute("CREATE DATABASE #{quoted_database}")
      rescue ConnectionAdapters::ClickHouse::HTTPConnection::ExecutionError => e
        raise DatabaseAlreadyExists if e.code == DATABASE_ALREADY_EXISTS_CODE

        raise
      end

      def drop
        server_execute("DROP DATABASE #{quoted_database}")
      rescue ConnectionAdapters::ClickHouse::HTTPConnection::ExecutionError => e
        raise NoDatabaseError, e.message if e.code == UNKNOWN_DATABASE_CODE

        raise
      end

      def purge
        drop
      rescue NoDatabaseError
        nil
      ensure
        create
      end

      def structure_dump(filename, _flags)
        establish_connection
        statements = dumpable_data_sources.map do |name|
          connection.select_value("SHOW CREATE TABLE #{connection.quote_table_name(name)}")
        end
        File.write(filename, statements.map { |statement| "#{statement};\n\n" }.join)
      end

      # Statements are separated by ";\n\n" exactly as structure_dump writes them —
      # ClickHouse HTTP accepts one statement per request, so the file is replayed.
      def structure_load(filename, _flags)
        establish_connection
        File.read(filename).split(";\n\n").each do |statement|
          statement = statement.strip
          connection.execute(statement) unless statement.empty?
        end
      end

      private

      # ignore_tables entries may be String, Regexp, or Proc — === is the contract
      # Rails' own SchemaDumper uses to match them.
      def dumpable_data_sources
        ignored = ActiveRecord::SchemaDumper.ignore_tables
        connection.data_sources.sort.reject { |name| ignored.any? { |pattern| pattern === name } } # rubocop:disable Style/CaseEquality
      end

      def quoted_database
        "`#{db_config.database.to_s.gsub("`", "``")}`"
      end

      def server_execute(sql)
        client = ConnectionAdapters::ClickHouse::HTTPConnection.new(
          configuration_hash.except(:adapter, :database)
        )
        client.execute(sql)
      ensure
        client&.close
      end
    end
  end
end
