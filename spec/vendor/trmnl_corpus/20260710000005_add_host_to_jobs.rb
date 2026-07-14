# frozen_string_literal: true

# Which box executed the job, so a wait spike attributes to one host's threads
# instead of reading as fleet-wide pressure.
class AddHostToJobs < ActiveRecord::Migration[8.1]
  def up = execute "ALTER TABLE jobs ADD COLUMN IF NOT EXISTS host LowCardinality(String) DEFAULT ''"
  def down = execute "ALTER TABLE jobs DROP COLUMN IF EXISTS host"
end
