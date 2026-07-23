# frozen_string_literal: true

class AddFirmwareOfferToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS update_offered UInt8 DEFAULT 0"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS target_firmware_version LowCardinality(String) DEFAULT ''"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS update_suppress_reason LowCardinality(String) DEFAULT ''"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS update_offered"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS target_firmware_version"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS update_suppress_reason"
  end
end
