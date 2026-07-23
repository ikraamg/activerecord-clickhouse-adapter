# frozen_string_literal: true

# Existing rows stay unlabelled (empty default) rather than backfilled with a guess.
class AddServerRoleToPostgresStatements < ActiveRecord::Migration[8.1]
  def up
    execute "ALTER TABLE postgres_statements ADD COLUMN IF NOT EXISTS server_role LowCardinality(String) DEFAULT ''"
  end

  def down
    execute "ALTER TABLE postgres_statements DROP COLUMN IF EXISTS server_role"
  end
end
