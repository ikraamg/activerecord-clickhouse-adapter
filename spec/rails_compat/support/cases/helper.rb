# frozen_string_literal: true

# Minimal stand-in for Rails' test/cases/helper.rb: enough infrastructure to run
# vendored Active Record suites (pinned to v8.1.3) against the ClickHouse adapter.
# Green = upstream pass or a skip documented in spec/rails_compat/skips.yml.

require "activerecord-clickhouse-adapter"
require "active_record/fixtures"
require "active_record/testing/query_assertions"
require "active_support/test_case"
require "active_support/testing/method_call_assertions"
# Upstream suites call bare class_eval inside test bodies; Kernel#class_eval comes
# from this core_ext, which the full Rails test env loads transitively.
require "active_support/core_ext/kernel/singleton_class"
# CopyMigrationsTest silences $stdout through this testing mixin.
require "active_support/testing/stream"
require "net/http"
require "yaml"

module ARCompat
  # skips.yml is the ratchet for the pinned corpus (vendor/UPSTREAM) on released
  # Rails and the ClickHouse floor. Overlays quarantine drift when that same corpus
  # runs against other versions; each loads only while its predicate holds and gets
  # deleted when the corpus is re-pinned past it.
  SKIP_OVERLAYS = {
    "skips_edge.yml" => -> { ActiveRecord.gem_version >= Gem::Version.new("8.2.0.alpha") }
  }.freeze

  SKIPS = YAML.load_file(File.expand_path("../../skips.yml", __dir__), aliases: true) || {}

  SKIP_OVERLAYS.each do |overlay, applies|
    next unless applies.call

    YAML.load_file(File.expand_path("../../#{overlay}", __dir__), aliases: true).each do |suite, tests|
      (SKIPS[suite] ||= {}).merge!(tests)
    end
  end

  # A suite-level "*" entry retires an entire vendored class. Per-test skips can't
  # cover a class whose own setup/teardown breaks on that Rails version — Minitest
  # runs teardown even for skipped tests. Called from run.rb once the cases are loaded.
  def self.apply_suite_exclusions
    SKIPS.each do |suite, tests|
      next unless tests.is_a?(Hash) && tests["*"]

      Object.const_get(suite).define_singleton_method(:runnable_methods) { [] }
    end
  end

  CONNECTION_CONFIG = {
    adapter: "clickhouse",
    host: ENV.fetch("CLICKHOUSE_HOST", "localhost"),
    port: Integer(ENV.fetch("CLICKHOUSE_HTTP_PORT", 18_123)),
    username: ENV.fetch("CLICKHOUSE_USER", "rails"),
    password: ENV.fetch("CLICKHOUSE_PASSWORD", "rails"),
    # Not ar_clickhouse_test: the embedding rspec process owns that namespace, and the
    # TRMNL corpus spec drops/recreates table names the schema slice also uses
    # (events/logs/jobs/...) — the presumed mechanism of the recurring full-gate storm.
    database: ENV.fetch("CLICKHOUSE_COMPAT_DATABASE", "ar_clickhouse_compat"),
    mutations_sync: 1
  }.freeze

  # ClickHouse refuses connections whose default database doesn't exist yet, so the
  # harness bootstraps its own database over raw HTTP before Active Record connects.
  def self.create_database
    uri = URI("http://#{CONNECTION_CONFIG[:host]}:#{CONNECTION_CONFIG[:port]}/")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(CONNECTION_CONFIG[:username], CONNECTION_CONFIG[:password])
    request.body = "CREATE DATABASE IF NOT EXISTS #{CONNECTION_CONFIG[:database]}"
    response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
    raise "harness database bootstrap failed: #{response.body}" unless response.is_a?(Net::HTTPSuccess)
  end
end

ARCompat.create_database

# Upstream test/support/connection.rb runs every suite with the global async query
# executor enabled; async-flavored tests assert payload[:async] on real thread-pool loads.
ActiveRecord.async_query_executor = :global_thread_pool

# Upstream registers arunit/arunit2 as named configurations so suites can
# `connects_to database: { writing: :arunit }`. Both point at the one test server
# here; cross-database distinctions get manifest skips.
ActiveRecord::Base.configurations = {
  "arunit" => ARCompat::CONNECTION_CONFIG.transform_keys(&:to_s),
  "arunit2" => ARCompat::CONNECTION_CONFIG.transform_keys(&:to_s)
}
ActiveRecord::Base.establish_connection(:arunit)

module ARCompat
  # Harness-side translation rule (PLAN.md §5 #14, same family as the schema-slice
  # rules): upstream migration suites create scratch tables inline with Rails'
  # implicit autoincrement id and no sorting key. Mirroring the schema slice, an
  # implicit id becomes an explicit Int64 column that doubles as the sorting key
  # (client-side prefetch populates it); id: false tables get an empty sorting key.
  # The adapter itself stays strict for real consumers.
  module InlineDDLDefaults
    def create_table(table_name, **options, &block)
      internal = [ActiveRecord::Base.schema_migrations_table_name,
                  ActiveRecord::Base.internal_metadata_table_name].include?(table_name.to_s)
      return super if internal || options.key?(:order)

      id = options.fetch(:id, :bigint)
      pk = options.fetch(:primary_key) { ActiveRecord::Base.get_primary_key(table_name.to_s.singularize) }
      return super(table_name, order: "tuple()", **options, &block) if id == false || pk.is_a?(Array)

      id_type = id == :primary_key ? :bigint : id
      super(table_name, **options.merge(id: false, order: quote_column_name(pk))) do |t|
        # primary_key: is DDL-inert here but lets Rails raise its dedicated
        # "can't redefine the primary key column" error on a duplicate.
        t.column pk, id_type, null: false, primary_key: true
        block&.call(t)
      end
    end
  end

  # Second translation rule, same family: upstream tests clean join tables with
  # portable-SQL `DELETE FROM t` strings. ClickHouse's lightweight DELETE demands an
  # explicit WHERE clause (SYNTAX_ERROR without one), and the adapter passes raw SQL
  # through untouched by design — so the harness pins the portable form to `WHERE 1`,
  # exactly what the Arel visitor emits for unscoped relation deletes.
  module BareDeleteTranslation
    BARE_DELETE = /\A\s*delete\s+from\s+(?:`[^`]+`|\S+)\s*\z/i

    # Hooked at the adapter's own wire funnel rather than execute/exec_delete: Rails
    # main routes connection.delete(sql) through QueryIntent#execute!, which skips
    # both public methods, but every version still lands here.
    def execute_wire_query(raw_connection, sql, ...)
      sql = "#{sql} WHERE 1" if sql.match?(BARE_DELETE)
      super
    end
  end
end
ActiveRecord::Base.lease_connection.class.prepend(ARCompat::InlineDDLDefaults)
ActiveRecord::Base.lease_connection.class.prepend(ARCompat::BareDeleteTranslation)

# Upstream helper.rb registers this stub adapter; ContactFakeColumns models connect
# to it to fake schema without a live table.
ActiveRecord::ConnectionAdapters.register(
  "fake", "FakeActiveRecordAdapter", File.expand_path("../../vendor/support/fake_adapter.rb", __dir__)
)

# Upstream test/support/global_config.rb runs the suites with these settings.
ActiveRecord.raise_on_missing_required_finder_order_columns = true
ActiveRecord.raise_on_assign_to_attr_readonly = true
ActiveRecord.belongs_to_required_validates_foreign_key = false

# Quote "type" if it's a reserved word for the current connection (upstream helper.rb).
QUOTED_TYPE = ActiveRecord::Base.lease_connection.quote_column_name("type")

# Upstream test/config.rb anchors this at test/migrations; the vendored copy lives
# beside the vendored cases.
MIGRATIONS_ROOT = File.expand_path("../../vendor/migrations", __dir__)

# Upstream test/config.rb: inheritance_test autoloads deliberately-broken model files
# from here to prove compute_type surfaces load-time errors.
MODELS_ROOT = File.expand_path("../../vendor/models", __dir__)

# Upstream defines this in test/cases/helper.rb; async query tests include it to
# drain the pool's async executor before asserting.
module WaitForAsyncTestHelper
  private

  def wait_for_async_query(connection = ActiveRecord::Base.lease_connection, timeout: 5)
    return unless connection.async_enabled?

    executor = connection.pool.async_executor
    (timeout * 100).times do
      return unless executor.scheduled_task_count > executor.completed_task_count

      sleep 0.01
    end

    raise Timeout::Error, "The async executor wasn't drained after #{timeout} seconds"
  end
end

# Upstream defines this in test/cases/helper.rb; dirty/attribute tests include it to
# toggle time_zone_aware_attributes around a block.
module InTimeZone
  private

  def in_time_zone(zone)
    old_zone = Time.zone
    old_tz = ActiveRecord::Base.time_zone_aware_attributes

    Time.zone = zone ? ActiveSupport::TimeZone[zone] : nil
    ActiveRecord::Base.time_zone_aware_attributes = !zone.nil?
    yield
  ensure
    Time.zone = old_zone
    ActiveRecord::Base.time_zone_aware_attributes = old_tz
  end
end

module ARCompat
  # Mirrors upstream's AdapterHelper, which is both included and extended.
  module AdapterHelper
    def current_adapter?(*names)
      names.include?(:ClickHouseAdapter)
    end

    def in_memory_db?
      false
    end

    # MySQL-only concern (upstream support/adapter_helper.rb); never applies here.
    def mysql_enforcing_gtid_consistency?
      false
    end

    # String columns take DEFAULT expressions like every other ClickHouse type.
    def supports_text_column_with_default?
      true
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

require "cases/validations_repair_helper"

module ActiveRecord
  class TestCase < ActiveSupport::TestCase
    include ActiveSupport::Testing::MethodCallAssertions
    include ActiveRecord::Assertions::QueryAssertions
    include ActiveRecord::TestFixtures
    include ActiveRecord::ValidationsRepairHelper
    include ARCompat::AdapterHelper
    extend ARCompat::AdapterHelper

    self.fixture_paths = [File.expand_path("../../vendor/fixtures", __dir__)]
    self.use_instantiated_fixtures = false
    # No transactions to roll back — fixture tables reload before every test and the
    # remaining schema-slice tables get truncated after it (PLAN.md §5 #15).
    self.use_transactional_tests = false

    # Manifest skips fire after the class's own setup, matching upstream's inline-skip
    # semantics: Minitest runs teardown even for skipped tests, and vendored teardowns
    # restore globals from ivars their setup captured — skipping before setup would
    # write those globals back as nil (seen live: yaml_column_permitted_classes).
    def after_setup
      super
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

    # Upstream test/cases/test_case.rb; schema-cache tests swap in a throwaway pool.
    def with_temporary_connection_pool(&)
      pool_config = ActiveRecord::Base.connection_pool.pool_config
      new_pool = ActiveRecord::ConnectionAdapters::ConnectionPool.new(pool_config)

      pool_config.stub(:pool, new_pool, &)
    ensure
      new_pool&.disconnect!
    end

    # Upstream defines these in test/cases/test_case.rb.
    def assert_column(model, column_name, msg = nil)
      model.reset_column_information
      assert_includes model.column_names, column_name.to_s, msg
    end

    def assert_no_column(model, column_name, msg = nil)
      model.reset_column_information
      assert_not_includes model.column_names, column_name.to_s, msg
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

    def reset_callbacks(klass, kind)
      old_callbacks = {}
      old_callbacks[klass] = klass.send("_#{kind}_callbacks").dup
      klass.subclasses.each do |subclass|
        old_callbacks[subclass] = subclass.send("_#{kind}_callbacks").dup
      end
      yield
    ensure
      klass.send("_#{kind}_callbacks=", old_callbacks[klass])
      klass.subclasses.each do |subclass|
        subclass.send("_#{kind}_callbacks=", old_callbacks[subclass])
      end
    end

    def with_has_many_inversing(model = ActiveRecord::Base)
      old = model.has_many_inversing
      model.has_many_inversing = true
      yield
    ensure
      model.has_many_inversing = old
    end

    def with_automatic_scope_inversing(*reflections)
      old = reflections.map { |reflection| reflection.klass.automatic_scope_inversing }

      reflections.each do |reflection|
        reflection.klass.automatic_scope_inversing = true
        reflection.remove_instance_variable(:@inverse_name) if reflection.instance_variable_defined?(:@inverse_name)
        reflection.remove_instance_variable(:@inverse_of) if reflection.instance_variable_defined?(:@inverse_of)
      end

      yield
    ensure
      reflections.each_with_index do |reflection, i|
        reflection.klass.automatic_scope_inversing = old[i]
        reflection.remove_instance_variable(:@inverse_name) if reflection.instance_variable_defined?(:@inverse_name)
        reflection.remove_instance_variable(:@inverse_of) if reflection.instance_variable_defined?(:@inverse_of)
      end
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
