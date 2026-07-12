# frozen_string_literal: true

class AddNoteToFlowProbe < ActiveRecord::Migration[8.1]
  def up
    add_column :flow_probe, :note, :string, null: true
  end

  def down
    remove_column :flow_probe, :note
  end
end
