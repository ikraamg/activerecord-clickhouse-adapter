# frozen_string_literal: true

# Which browser rendered each event (firefox/chrome/composition), so render latency splits per
# pool without inferring the engine from the plugin.
class AddEngineToEvents < ActiveRecord::Migration[8.1]
  def up = execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS engine LowCardinality(String) DEFAULT ''"
  def down = execute "ALTER TABLE events DROP COLUMN IF EXISTS engine"
end
