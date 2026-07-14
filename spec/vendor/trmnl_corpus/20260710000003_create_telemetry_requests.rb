# frozen_string_literal: true

# One row per dashboard/API controller action (Telemetry.record_request); device traffic is
# excluded at the emitter because it is already in events. ORDER BY (controller, action, ts) so
# per-endpoint queries read only that action; 7 days is enough for recent-request debugging.
class CreateTelemetryRequests < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS requests (
        ts          DateTime64(3, 'UTC') DEFAULT now64(3),
        method      LowCardinality(String) DEFAULT '',
        path        String DEFAULT '',
        controller  LowCardinality(String) DEFAULT '',
        action      LowCardinality(String) DEFAULT '',
        status      UInt16 DEFAULT 0,
        duration_ms UInt32 DEFAULT 0,
        db_ms       Nullable(UInt32),
        user_id     UInt64 DEFAULT 0,
        INDEX idx_user user_id TYPE bloom_filter GRANULARITY 4
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (controller, action, ts)
      TTL toDateTime(ts) + INTERVAL 7 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS requests")
end
