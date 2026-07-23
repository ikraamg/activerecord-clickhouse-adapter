# frozen_string_literal: true

# browser+magick paint isn't stored directly: paint = duration_ms - build_ms.
class AddPhaseTimingsToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS build_ms UInt32 DEFAULT 0"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS upload_ms UInt32 DEFAULT 0"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS build_ms"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS upload_ms"
  end
end
