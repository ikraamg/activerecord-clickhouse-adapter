# frozen_string_literal: true

require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/clickhouse/database_statements"
require "active_record/connection_adapters/clickhouse/http_connection"
require "active_record/connection_adapters/clickhouse/type_parser"
require "active_record/connection_adapters/clickhouse/types"

module ActiveRecord
  module ConnectionAdapters
    class ClickHouseAdapter < AbstractAdapter
      ADAPTER_NAME = "ClickHouse"

      include ClickHouse::DatabaseStatements

      class << self
        def new_client(config)
          ClickHouse::HTTPConnection.new(config)
        end
      end

      def initialize(...)
        super

        @connection_parameters = {
          host: @config.fetch(:host, "localhost"),
          port: @config.fetch(:port, 8123),
          username: @config[:username],
          password: @config[:password],
          database: @config[:database],
          ssl: @config[:ssl],
          connect_timeout: @config[:connect_timeout],
          read_timeout: @config[:read_timeout],
          write_timeout: @config[:write_timeout]
        }.compact
      end

      def active?
        @lock.synchronize { @raw_connection&.ping } || false
      end

      def disconnect!
        super
        @raw_connection&.close
        @raw_connection = nil
      end

      def get_database_version # :nodoc:
        Version.new(query_value("SELECT version()", "SCHEMA"))
      end

      private

      def connect
        @raw_connection = self.class.new_client(@connection_parameters)
      end

      def reconnect
        @raw_connection&.close
        connect
      end

      # ClickHouse has no prepared statements; binds become server-side {name:Type} parameters.
      def default_prepared_statements = false
    end
  end
end
