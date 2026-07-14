# frozen_string_literal: true

# Timezone-less DateTime columns parse incoming strings in the SERVER's timezone; Rails always
# sends UTC. Pinning 'UTC' makes the parse correct regardless of server config. Metadata-only
# ALTER (storage is epoch), safe on ORDER BY key columns — verified against the local container.
class PinUtcOnTimestampColumns < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events MODIFY COLUMN ts DateTime64(3, 'UTC') DEFAULT now64(3)"
    execute "ALTER TABLE events MODIFY COLUMN refresh_at_before Nullable(DateTime('UTC'))"
    execute "ALTER TABLE events MODIFY COLUMN refresh_at_after Nullable(DateTime('UTC'))"
    execute "ALTER TABLE logs MODIFY COLUMN ts DateTime64(3, 'UTC') DEFAULT now64(3)"
  end

  def down
    execute "ALTER TABLE events MODIFY COLUMN ts DateTime64(3) DEFAULT now64(3)"
    execute "ALTER TABLE events MODIFY COLUMN refresh_at_before Nullable(DateTime)"
    execute "ALTER TABLE events MODIFY COLUMN refresh_at_after Nullable(DateTime)"
    execute "ALTER TABLE logs MODIFY COLUMN ts DateTime64(3) DEFAULT now64(3)"
  end
end
