# frozen_string_literal: true

# Minimal stand-in for Rails' test/cases/helper.rb: enough infrastructure to run
# vendored Active Record suites (pinned to v8.1.3) against the ClickHouse adapter.
# Green = upstream pass or a skip documented in spec/rails_compat/skips.yml.

require "activerecord-clickhouse-adapter"
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

module ActiveRecord
  class TestCase < ActiveSupport::TestCase
    include ActiveSupport::Testing::MethodCallAssertions

    setup do
      reason = ARCompat::SKIPS.dig(self.class.name, name)
      skip(reason) if reason
    end

    def current_adapter?(*names)
      names.include?(:ClickHouseAdapter)
    end

    def with_timezone_config(default: :__unset)
      previous = ActiveRecord.default_timezone
      ActiveRecord.default_timezone = default unless default == :__unset
      yield
    ensure
      ActiveRecord.default_timezone = previous
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
