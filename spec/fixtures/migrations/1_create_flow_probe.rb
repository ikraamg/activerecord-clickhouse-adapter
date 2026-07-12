# frozen_string_literal: true

class CreateFlowProbe < ActiveRecord::Migration[8.1]
  def change
    create_table :flow_probe, order: "(device_id, ts)", partition: "toDate(ts)" do |t|
      t.integer :device_id, limit: 8
      t.datetime :ts, default: -> { "now64(3)" }
      t.string :tag, low_cardinality: true, default: ""
    end
  end
end
