# frozen_string_literal: true

# One row per deploy; a handful of rows a day, so monthly partitions and a year of history.
class CreateDeploys < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS deploys (
        ts       DateTime64(3, 'UTC') DEFAULT now64(3),
        revision String DEFAULT '',
        host     LowCardinality(String) DEFAULT ''
      )
      ENGINE = MergeTree
      PARTITION BY toYYYYMM(ts)
      ORDER BY ts
      TTL toDateTime(ts) + INTERVAL 365 DAY
      SETTINGS ttl_only_drop_parts = 1
    SQL
  end

  def down = execute("DROP TABLE IF EXISTS deploys")
end
