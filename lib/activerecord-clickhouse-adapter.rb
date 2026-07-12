# frozen_string_literal: true

require "active_record"
require "active_record/connection_adapters"
require "active_record/connection_adapters/clickhouse/gem_version"
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
