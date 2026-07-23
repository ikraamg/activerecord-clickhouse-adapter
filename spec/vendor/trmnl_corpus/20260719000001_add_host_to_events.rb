# frozen_string_literal: true

# Only render rows set host; other event types keep the default ''.
class AddHostToEvents < ActiveRecord::Migration[8.1]
  def up = execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS host LowCardinality(String) DEFAULT ''"
  def down = execute "ALTER TABLE events DROP COLUMN IF EXISTS host"
end
