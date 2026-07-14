# frozen_string_literal: true

# Carries WHY a render failed (timeout class, readiness give-up, page console errors) next to
# the existing status column. The by_source projection expanded SELECT * at creation, so it
# must be rebuilt to carry the new column — otherwise queries reading `error` skip it.
class AddErrorToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS error String DEFAULT '' AFTER skip_reason"
    rebuild_source_projection
  end

  def down
    execute "ALTER TABLE events DROP PROJECTION IF EXISTS by_source"
    execute "ALTER TABLE events DROP COLUMN IF EXISTS error"
    rebuild_source_projection
  end

  private

  def rebuild_source_projection
    execute "ALTER TABLE events DROP PROJECTION IF EXISTS by_source"
    execute "ALTER TABLE events ADD PROJECTION by_source (SELECT * ORDER BY (source_type, source_id, ts))"
    # Async backfill of pre-existing parts; new inserts carry the projection immediately.
    execute "ALTER TABLE events MATERIALIZE PROJECTION by_source"
  end
end
