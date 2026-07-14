# frozen_string_literal: true

# Typed sink for fleet telemetry: one row per check-in / arm / render / serve, discriminated by
# event_type. Raw DDL so the ClickHouse-native types (Enum8, LowCardinality, Nullable) are exact
# — no free-form JSON blob. Postgres ids stay typed columns (with bloom skip-indexes) so
# console/BI can search by device / user / source / screen / playlist item.
#
# Bounded + disposable: MergeTree ordered for device-scoped time scans, 30-day TTL, one-command
# teardown (docker compose -f docker-compose.clickhouse.yml down -v).
class CreateEvents < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS events (
        ts                DateTime64(3) DEFAULT now64(3),
        event_type        Enum8('checkin' = 1, 'arm' = 2, 'render' = 3, 'serve' = 4),
        device_id         UInt64 DEFAULT 0,
        user_id           UInt64 DEFAULT 0,
        source_type       LowCardinality(String) DEFAULT '',
        source_id         Nullable(UInt64),
        playlist_item_id  Nullable(UInt64),
        position          Nullable(Int64),
        screen_id         Nullable(UInt64),
        appearance        LowCardinality(String) DEFAULT '',
        status            LowCardinality(String) DEFAULT '',
        firmware_version  LowCardinality(String) DEFAULT '',
        refresh_rate      Nullable(UInt32),
        refresh_at_before Nullable(DateTime),
        refresh_at_after  Nullable(DateTime),
        armed             UInt8 DEFAULT 0,
        skip_reason       LowCardinality(String) DEFAULT '',
        duration_ms       Nullable(UInt32),
        bytes             Nullable(UInt32),
        INDEX idx_source source_id       TYPE bloom_filter GRANULARITY 4,
        INDEX idx_screen screen_id       TYPE bloom_filter GRANULARITY 4,
        INDEX idx_item   playlist_item_id TYPE bloom_filter GRANULARITY 4
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (device_id, ts)
      TTL toDateTime(ts) + INTERVAL 30 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS events"
  end
end
