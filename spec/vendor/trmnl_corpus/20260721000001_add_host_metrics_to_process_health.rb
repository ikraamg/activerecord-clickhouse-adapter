# frozen_string_literal: true

class AddHostMetricsToProcessHealth < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE process_health ADD COLUMN IF NOT EXISTS memory_bytes Nullable(UInt64)"
    execute "ALTER TABLE process_health ADD COLUMN IF NOT EXISTS load_average_one_minute Nullable(Float32)"
    execute "ALTER TABLE process_health ADD COLUMN IF NOT EXISTS temporary_directory_free_bytes Nullable(UInt64)"
  end

  def down
    execute "ALTER TABLE process_health DROP COLUMN IF EXISTS memory_bytes"
    execute "ALTER TABLE process_health DROP COLUMN IF EXISTS load_average_one_minute"
    execute "ALTER TABLE process_health DROP COLUMN IF EXISTS temporary_directory_free_bytes"
  end
end
