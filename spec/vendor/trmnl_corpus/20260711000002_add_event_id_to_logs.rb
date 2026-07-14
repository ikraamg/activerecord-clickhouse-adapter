# frozen_string_literal: true

class AddEventIdToLogs < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE logs ADD COLUMN IF NOT EXISTS event_id UUID DEFAULT generateUUIDv4() AFTER ts"
    active_partition_ids.each do |partition_id|
      execute "ALTER TABLE logs MATERIALIZE COLUMN event_id IN PARTITION ID '#{partition_id}' SETTINGS mutations_sync = 2"
    end
  end

  def down
    execute "ALTER TABLE logs DROP COLUMN IF EXISTS event_id"
  end

  private

  def active_partition_ids
    connection.select_values(<<~SQL.squish)
      SELECT DISTINCT _partition_id
      FROM logs
      ORDER BY _partition_id
    SQL
  end
end
