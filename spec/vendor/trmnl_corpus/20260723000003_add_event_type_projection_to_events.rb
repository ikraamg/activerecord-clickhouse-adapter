# frozen_string_literal: true

# event_type isn't in the sort key, so filtering on it scans every row; this copy sorts by
# (event_type, ts) to narrow those reads. Same SELECT * gotcha as by_source. Costs a third copy
# per insert, and MATERIALIZE keeps merge load high until the backfill finishes.
class AddEventTypeProjectionToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD PROJECTION by_event_type (SELECT * ORDER BY (event_type, ts))"
    execute "ALTER TABLE events MATERIALIZE PROJECTION by_event_type"
  end

  def down
    execute "ALTER TABLE events DROP PROJECTION IF EXISTS by_event_type"
  end
end
