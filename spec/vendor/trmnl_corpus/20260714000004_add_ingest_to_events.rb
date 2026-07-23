# frozen_string_literal: true

class AddIngestToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, 'ingest' = 5)"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS ingest_channel LowCardinality(String) DEFAULT ''"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS ingest_channel"
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4)"
  end
end
