# frozen_string_literal: true

class AddRetryCountToJobs < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE jobs ADD COLUMN IF NOT EXISTS retry_count Nullable(UInt16)"
  end

  def down
    execute "ALTER TABLE jobs DROP COLUMN IF EXISTS retry_count"
  end
end
