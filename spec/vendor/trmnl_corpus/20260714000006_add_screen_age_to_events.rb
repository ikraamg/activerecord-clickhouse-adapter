# frozen_string_literal: true

class AddScreenAgeToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS screen_age_seconds Nullable(UInt32)"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS screen_age_seconds"
  end
end
