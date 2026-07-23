# frozen_string_literal: true

class CreateFetches < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS fetches (
        ts                DateTime64(3, 'UTC') DEFAULT now64(3),
        plugin_keyname    LowCardinality(String) DEFAULT '',
        plugin_setting_id Nullable(UInt64),
        user_id           UInt64 DEFAULT 0,
        http_method       LowCardinality(String) DEFAULT '',
        url_host          LowCardinality(String) DEFAULT '',
        status            UInt16 DEFAULT 0,
        outcome           LowCardinality(String) DEFAULT '',
        duration_ms       UInt32 DEFAULT 0,
        bytes             Nullable(UInt32),
        etag_hit          UInt8 DEFAULT 0
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (plugin_keyname, ts)
      TTL toDateTime(ts) + INTERVAL 14 DAY
      SETTINGS index_granularity = 8192
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS fetches")
end
