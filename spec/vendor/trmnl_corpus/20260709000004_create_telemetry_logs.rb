# frozen_string_literal: true

# One row per Postgres Log (device / private_plugin / mashup / support), so log history builds up
# here before Postgres logging is retired. `log_id` is the Postgres primary key — 0 when the row
# exists only here, i.e. debug logs Postgres dropped. `source`/`level` are strings, not Enum8, so
# a new Rails enum value can never make ClickHouse reject a whole batch. Named CreateTelemetryLogs
# because db:migrate loads db/migrate (which already defines CreateLogs for Postgres) before
# clickhouse:migrate loads this file.
class CreateTelemetryLogs < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS logs (
        ts                DateTime64(3) DEFAULT now64(3),
        log_id            UInt64 DEFAULT 0,
        source            LowCardinality(String) DEFAULT '',
        level             LowCardinality(String) DEFAULT '',
        device_id         UInt64 DEFAULT 0,
        user_id           UInt64 DEFAULT 0,
        plugin_setting_id Nullable(UInt64),
        mashup_id         Nullable(UInt64),
        dump              String DEFAULT '',
        INDEX idx_plugin_setting plugin_setting_id TYPE bloom_filter GRANULARITY 4,
        INDEX idx_mashup         mashup_id         TYPE bloom_filter GRANULARITY 4,
        INDEX idx_user           user_id           TYPE bloom_filter GRANULARITY 4
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (device_id, ts)
      TTL toDateTime(ts) + INTERVAL 30 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS logs"
  end
end
