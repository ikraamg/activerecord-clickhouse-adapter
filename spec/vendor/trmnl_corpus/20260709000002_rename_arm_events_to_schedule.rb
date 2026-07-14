# frozen_string_literal: true

# The enum keeps value 2, so historical rows re-read under the new name with no data rewrite.
class RenameArmEventsToSchedule < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4)"
    execute "ALTER TABLE events RENAME COLUMN armed TO scheduled"
  end

  def down
    execute "ALTER TABLE events RENAME COLUMN scheduled TO armed"
    execute "ALTER TABLE events MODIFY COLUMN event_type Enum8('checkin' = 1, 'arm' = 2, 'render' = 3, 'serve' = 4)"
  end
end
