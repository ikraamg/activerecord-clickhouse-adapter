# frozen_string_literal: true

# Matches the retention Postgres always had: purge_old_data trims Log at 2 weeks, so 30 days
# here kept log history no page ever showed.
class ReduceLogsTTLToFourteenDays < ActiveRecord::Migration[8.1]
  def up = execute("ALTER TABLE logs MODIFY TTL toDateTime(ts) + INTERVAL 14 DAY")

  def down = execute("ALTER TABLE logs MODIFY TTL toDateTime(ts) + INTERVAL 30 DAY")
end
