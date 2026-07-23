# frozen_string_literal: true

class AddOauthToEvents < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, 'ingest' = 5, 'setup' = 6, 'reset' = 7, 'oauth' = 8)"
    execute "ALTER TABLE events ADD COLUMN IF NOT EXISTS oauth_provider LowCardinality(String) DEFAULT ''"
  end

  def down
    execute "ALTER TABLE events DROP COLUMN IF EXISTS oauth_provider"
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, 'ingest' = 5, 'setup' = 6, 'reset' = 7)"
  end
end
