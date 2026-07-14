# frozen_string_literal: true

# Model and channel ride on every event so firmware questions (adoption, silent share)
# split by device model and release channel without a Postgres join.
class AddDeviceContextToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS model_id UInt32 DEFAULT 0"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS channel LowCardinality(String) DEFAULT ''"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS model_id"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS channel"
  end
end
