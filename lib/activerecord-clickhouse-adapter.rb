# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters"
require "active_record/connection_adapters/clickhouse/gem_version"

ActiveRecord::ConnectionAdapters.register(
  "clickhouse",
  "ActiveRecord::ConnectionAdapters::ClickHouseAdapter",
  "active_record/connection_adapters/clickhouse_adapter"
)
