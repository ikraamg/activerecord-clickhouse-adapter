# frozen_string_literal: true

# Battery voltage/percent per check-in, so /admin can graph discharge over time per device and a
# later anomaly detector can key on the discharge slope. Measures, not dimensions — kept out of
# the ORDER BY.
class AddBatteryToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS battery_voltage Nullable(Float32)"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS battery_percent Nullable(UInt8)"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS battery_voltage"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS battery_percent"
  end
end
