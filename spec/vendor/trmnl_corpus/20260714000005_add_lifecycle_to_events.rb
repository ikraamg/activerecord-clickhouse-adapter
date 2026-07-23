# frozen_string_literal: true

class AddLifecycleToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, 'ingest' = 5, 'setup' = 6, 'reset' = 7)"
  end

  def down
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, 'ingest' = 5)"
  end
end
