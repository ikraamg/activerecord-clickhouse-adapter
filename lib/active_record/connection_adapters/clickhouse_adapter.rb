# frozen_string_literal: true

require "active_record/connection_adapters/abstract_adapter"
require "active_record/connection_adapters/clickhouse/database_statements"
require "active_record/connection_adapters/clickhouse/error_translation"
require "active_record/connection_adapters/clickhouse/http_connection"
require "active_record/connection_adapters/clickhouse/querying"
require "active_record/connection_adapters/clickhouse/quoting"
require "active_record/connection_adapters/clickhouse/row_binary"
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
        host port username password database ssl ssl_verify select_format
        connect_timeout read_timeout write_timeout
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

      # With cluster: configured, schema DDL is stamped ON CLUSTER so every replica
      # runs it through the distributed DDL queue.
      def cluster = @config[:cluster]

      def on_cluster_clause
        cluster ? " ON CLUSTER #{quote_table_name(cluster)}" : ""
      end

      # Closing inside @lock keeps a queued query (which holds the lock for its whole
      # HTTP round-trip) from starting on a socket that dies mid-read — the postgresql
      # adapter's own disconnect! pattern.
      def disconnect!
        @lock.synchronize do
          super
          @raw_connection&.close
          @raw_connection = nil
        end
      end

      def supports_explain? = true

      # DateTime64(P) is native precision; claiming it makes the DSL apply Rails'
      # default microsecond precision (6) to datetime columns, like other adapters.
      def supports_datetime_with_precision? = true

      # Data-skipping indexes are INDEX clauses inside CREATE TABLE, not statements.
      def supports_indexes_in_create? = true

      # insert_all implies skip-duplicates; without unique constraints nothing can
      # conflict, so the semantics hold vacuously and the INSERT goes through plain.
      # Upsert still raises upstream (supports_insert_on_duplicate_update? is false).
      def supports_insert_on_duplicate_skip? = true

      def build_insert_sql(insert) = "INSERT #{insert.into} #{insert.values_list}" # :nodoc:

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
