# frozen_string_literal: true

# By default expired rows are removed by merges that rewrite the part. Our partitions are daily
# and every TTL is a whole-day offset, so a part's rows all expire together: dropping the whole
# part skips the merge work and is at most one day late.
class DropWholePartsOnTTL < ActiveRecord::Migration[8.1]
  TABLES = %w[events logs jobs requests].freeze

  def up
    TABLES.each { |table| execute("ALTER TABLE #{table} MODIFY SETTING ttl_only_drop_parts = 1") }
  end

  def down
    TABLES.each { |table| execute("ALTER TABLE #{table} RESET SETTING ttl_only_drop_parts") }
  end
end
