# frozen_string_literal: true

require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/clickhouse/database_statements"
require "active_record/connection_adapters/clickhouse/error_translation"
require "active_record/connection_adapters/clickhouse/http_connection"
require "active_record/connection_adapters/clickhouse/querying"
require "active_record/connection_adapters/clickhouse/quoting"
require "active_record/connection_adapters/clickhouse/schema_definitions"
require "active_record/connection_adapters/clickhouse/schema_dumper"
require "active_record/connection_adapters/clickhouse/schema_statements"
require "active_record/connection_adapters/clickhouse/type_parser"
require "active_record/connection_adapters/clickhouse/types"
require "arel/visitors/clickhouse"

module ActiveRecord
  module ConnectionAdapters
    class ClickHouseAdapter < AbstractAdapter
      ADAPTER_NAME = "ClickHouse"

      include ClickHouse::Quoting
      include ClickHouse::DatabaseStatements
      include ClickHouse::SchemaStatements
      include ClickHouse::ErrorTranslation

      class << self
        def new_client(config)
          ClickHouse::HTTPConnection.new(config)
        end
      end

      CONNECTION_PARAMETER_KEYS = %i[
        host port username password database ssl connect_timeout read_timeout write_timeout
        mutations_sync compression join_use_nulls async_insert wait_for_async_insert
      ].freeze

      def initialize(...)
        super

        @connection_parameters =
          { host: "localhost", port: 8123 }.merge(@config.slice(*CONNECTION_PARAMETER_KEYS)).compact
      end

      def active?
        @lock.synchronize { @raw_connection&.ping } || false
      end

      def disconnect!
        super
        @raw_connection&.close
        @raw_connection = nil
      end

      def supports_explain? = true

      # Data-skipping indexes are INDEX clauses inside CREATE TABLE, not statements.
      def supports_indexes_in_create? = true

      NATIVE_DATABASE_TYPES = {
        string: { name: "String" },
        text: { name: "String" },
        integer: { name: "Int32", limit: 4 },
        bigint: { name: "Int64", limit: 8 },
        float: { name: "Float64" },
        decimal: { name: "Decimal" },
        datetime: { name: "DateTime64" },
        date: { name: "Date32" },
        boolean: { name: "Bool" },
        uuid: { name: "UUID" },
        json: { name: "JSON" }
      }.freeze

      def native_database_types = NATIVE_DATABASE_TYPES

      # Column types the dumper can't map to AR symbols (Array, Map, Tuple, ...) are
      # dumped verbatim, so every introspected type is valid by construction.
      def valid_type?(_type) = true

      def create_schema_dumper(options) # :nodoc:
        ClickHouse::SchemaDumper.create(self, options)
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

      # No server-side prepared statements; `true` selects the Arel Bind collector so we can
      # rewrite `?` into ClickHouse `{pN:Type}` HTTP query parameters in perform_query.
      def default_prepared_statements = true

      def arel_visitor = Arel::Visitors::ClickHouse.new(self)
    end
  end
end
