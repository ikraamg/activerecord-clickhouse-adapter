# frozen_string_literal: true

# The three tables DropWholePartsOnTTL missed. Same reasoning: daily partitions and a whole-day
# TTL offset mean a part's rows all expire together, so dropping the part beats rewriting it.
class DropWholePartsOnTTLForRemainingTables < ActiveRecord::Migration[8.1]
  TABLES = %w[fetches pool_events process_health].freeze

  def up
    TABLES.each { |table| execute("ALTER TABLE #{table} MODIFY SETTING ttl_only_drop_parts = 1") }
  end

  def down
    TABLES.each { |table| execute("ALTER TABLE #{table} RESET SETTING ttl_only_drop_parts") }
  end
end
