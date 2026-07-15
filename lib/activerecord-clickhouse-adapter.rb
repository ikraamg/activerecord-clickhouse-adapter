# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters"
require "active_record/connection_adapters/clickhouse/gem_version"
# Eager so models can `include ...ClickHouse::Querying` at boot, before (or without)
# any ClickHouse connection loading the adapter — e.g. app code shared across envs
# where the sink is only wired in production.
require "active_record/connection_adapters/clickhouse/querying"
require "active_record/tasks/clickhouse_database_tasks"

ActiveRecord::ConnectionAdapters.register(
  "clickhouse",
  "ActiveRecord::ConnectionAdapters::ClickHouseAdapter",
  "active_record/connection_adapters/clickhouse_adapter"
)

ActiveRecord::Tasks::DatabaseTasks.register_task(
  /clickhouse/,
  "ActiveRecord::Tasks::ClickHouseDatabaseTasks"
)
