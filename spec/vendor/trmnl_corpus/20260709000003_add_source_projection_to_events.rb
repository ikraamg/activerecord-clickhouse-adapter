# frozen_string_literal: true

# The table is sorted by (device_id, ts), so a PluginSetting/Mashup activity page scans every
# row. The projection keeps a second copy sorted by source, so those reads narrow too.
# Gotcha: SELECT * is expanded at creation — columns added later stay out of the projection.
class AddSourceProjectionToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD PROJECTION by_source (SELECT * ORDER BY (source_type, source_id, ts))"
    # Async backfill of pre-existing parts; new inserts carry the projection immediately.
    execute "ALTER TABLE events MATERIALIZE PROJECTION by_source"
  end

  def down
    execute "ALTER TABLE events DROP PROJECTION IF EXISTS by_source"
  end
end
