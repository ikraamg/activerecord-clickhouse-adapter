# frozen_string_literal: true

# Counters are cumulative per query_id, so ORDER BY keeps a statement's history contiguous
# and the repeated query text compresses away.
class CreatePostgresStatements < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE IF NOT EXISTS postgres_statements (
        ts DateTime64(3, 'UTC') DEFAULT now64(3),
        query_id Int64,
        calls UInt64,
        total_exec_time_ms Float64,
        rows_processed UInt64,
        shared_blocks_hit UInt64,
        shared_blocks_read UInt64,
        shared_blocks_dirtied UInt64,
        shared_blocks_written UInt64,
        temporary_blocks_read UInt64,
        temporary_blocks_written UInt64,
        wal_records UInt64,
        wal_full_page_images UInt64,
        wal_bytes UInt64,
        query String
      ) ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (query_id, ts)
      TTL toDateTime(ts) + toIntervalDay(30)
      SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1
    SQL
  end

  def down
    execute "DROP TABLE IF EXISTS postgres_statements"
  end
end
