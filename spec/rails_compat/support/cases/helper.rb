# frozen_string_literal: true

# Minimal stand-in for Rails' test/cases/helper.rb: enough infrastructure to run
# vendored Active Record suites (pinned to v8.1.3) against the ClickHouse adapter.
# Green = upstream pass or a skip documented in spec/rails_compat/skips.yml.

require "activerecord-clickhouse-adapter"
require "active_record/fixtures"
require "active_record/testing/query_assertions"
require "active_support/test_case"
require "active_support/testing/method_call_assertions"
require "yaml"

module ARCompat
  SKIPS = YAML.load_file(File.expand_path("../../skips.yml", __dir__)) || {}

  CONNECTION_CONFIG = {
    adapter: "clickhouse",
    host: ENV.fetch("CLICKHOUSE_HOST", "localhost"),
    port: Integer(ENV.fetch("CLICKHOUSE_HTTP_PORT", 18_123)),
    username: ENV.fetch("CLICKHOUSE_USER", "rails"),
    password: ENV.fetch("CLICKHOUSE_PASSWORD", "rails"),
    database: ENV.fetch("CLICKHOUSE_DATABASE", "ar_clickhouse_test"),
    mutations_sync: 1
  }.freeze
end

ActiveRecord::Base.establish_connection(ARCompat::CONNECTION_CONFIG)

# Upstream test/support/global_config.rb runs the suites with this future default on.
ActiveRecord.raise_on_missing_required_finder_order_columns = true

# Quote "type" if it's a reserved word for the current connection (upstream helper.rb).
QUOTED_TYPE = ActiveRecord::Base.lease_connection.quote_column_name("type")

module ARCompat
  # Mirrors upstream's AdapterHelper, which is both included and extended.
  module AdapterHelper
    def current_adapter?(*names)
      names.include?(:ClickHouseAdapter)
    end

    def in_memory_db?
      false
    end

    # Upstream delegates these capability predicates to the live connection so the
    # vendored suites can self-skip features the adapter doesn't claim.
    %w[
      supports_savepoints?
      supports_partial_index?
      supports_partitioned_indexes?
      supports_expression_index?
      supports_index_include?
      supports_insert_returning?
      supports_insert_on_duplicate_skip?
      supports_insert_on_duplicate_update?
      supports_insert_conflict_target?
      supports_optimizer_hints?
      supports_datetime_with_precision?
      supports_nulls_not_distinct?
      supports_identity_columns?
      supports_virtual_columns?
      supports_native_partitioning?
    ].each do |method_name|
      define_method method_name do
        ActiveRecord::Base.lease_connection.public_send(method_name)
      end
    end
  end
end

module ActiveRecord
  class TestCase < ActiveSupport::TestCase
    include ActiveSupport::Testing::MethodCallAssertions
    include ActiveRecord::Assertions::QueryAssertions
    include ActiveRecord::TestFixtures
    include ARCompat::AdapterHelper
    extend ARCompat::AdapterHelper

    self.fixture_paths = [File.expand_path("../../vendor/fixtures", __dir__)]
    self.use_instantiated_fixtures = false
    # No transactions to roll back — fixture tables reload before every test and the
    # remaining schema-slice tables get truncated after it (PLAN.md §5 #15).
    self.use_transactional_tests = false

    setup do
      reason = ARCompat::SKIPS.dig(self.class.name, name)
      skip(reason) if reason
    end

    teardown do
      if defined?(ARCompat::SchemaSlice)
        stale_tables = ARCompat::SchemaSlice::TABLES - self.class.fixture_table_names.map(&:to_s)
        connection = ActiveRecord::Base.lease_connection
        stale_tables.each { |table| connection.execute("TRUNCATE TABLE #{connection.quote_table_name(table)}") }
      end
    end

    def quote_table_name(name)
      ActiveRecord::Base.adapter_class.quote_table_name(name)
    end

    def capture_sql(include_schema: false)
      counter = ActiveRecord::Assertions::QueryAssertions::SQLCounter.new
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        yield
        include_schema ? counter.log_all : counter.log
      end
    end

    def with_timezone_config(cfg)
      old_default_zone = ActiveRecord.default_timezone
      old_awareness = ActiveRecord::Base.time_zone_aware_attributes
      old_aware_types = ActiveRecord::Base.time_zone_aware_types
      old_zone = Time.zone

      ActiveRecord.default_timezone = cfg[:default] if cfg.key?(:default)
      ActiveRecord::Base.time_zone_aware_attributes = cfg[:aware_attributes] if cfg.key?(:aware_attributes)
      ActiveRecord::Base.time_zone_aware_types = cfg[:aware_types] if cfg.key?(:aware_types)
      Time.zone = cfg[:zone] if cfg.key?(:zone)
      yield
    ensure
      ActiveRecord.default_timezone = old_default_zone
      ActiveRecord::Base.time_zone_aware_attributes = old_awareness
      ActiveRecord::Base.time_zone_aware_types = old_aware_types
      Time.zone = old_zone
    end

    def with_env_tz(new_tz = "US/Eastern")
      old_tz = ENV.fetch("TZ", nil)
      ENV["TZ"] = new_tz
      yield
    ensure
      old_tz ? ENV["TZ"] = old_tz : ENV.delete("TZ")
    end
  end
end

require "minitest/autorun"
