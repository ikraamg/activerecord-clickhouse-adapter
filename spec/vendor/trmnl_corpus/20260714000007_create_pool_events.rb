# frozen_string_literal: true

class CreatePoolEvents < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS pool_events (
        ts           DateTime64(3, 'UTC') DEFAULT now64(3),
        host         LowCardinality(String) DEFAULT '',
        pool         LowCardinality(String) DEFAULT '',
        event        LowCardinality(String) DEFAULT '',
        reason       LowCardinality(String) DEFAULT '',
        duration_ms  Nullable(UInt32),
        memory_bytes Nullable(UInt64),
        error        String DEFAULT ''
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (pool, ts)
      TTL toDateTime(ts) + INTERVAL 14 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS pool_events")
end
