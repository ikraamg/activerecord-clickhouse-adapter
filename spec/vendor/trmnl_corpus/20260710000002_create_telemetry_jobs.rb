# frozen_string_literal: true

# One row per executed Sidekiq job (Telemetry.record_job). ORDER BY (job_class, ts) so
# per-worker queries read only that class; 14 days covers week-over-week comparison.
class CreateTelemetryJobs < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS jobs (
        ts          DateTime64(3, 'UTC') DEFAULT now64(3),
        job_class   LowCardinality(String) DEFAULT '',
        queue       LowCardinality(String) DEFAULT '',
        status      LowCardinality(String) DEFAULT '',
        duration_ms UInt32 DEFAULT 0,
        wait_ms     Nullable(UInt32),
        error_class LowCardinality(String) DEFAULT '',
        error       String DEFAULT ''
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (job_class, ts)
      TTL toDateTime(ts) + INTERVAL 14 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS jobs")
end
