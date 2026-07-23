# frozen_string_literal: true

# One row per scheduler-lag sample (Telemetry.record_process_health). ORDER BY (host, ts)
# for per-box starvation queries; 14 days matches jobs retention.
class CreateProcessHealth < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS process_health (
        ts                   DateTime64(3, 'UTC') DEFAULT now64(3),
        host                 LowCardinality(String) DEFAULT '',
        scheduler_lag_avg_ms UInt32 DEFAULT 0,
        scheduler_lag_max_ms UInt32 DEFAULT 0,
        thread_count         UInt16 DEFAULT 0
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (host, ts)
      TTL toDateTime(ts) + INTERVAL 14 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS process_health")
end
