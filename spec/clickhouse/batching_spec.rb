# frozen_string_literal: true

# Rails' stock batching (WHERE pk > last ORDER BY pk LIMIT n) is already the
# ClickHouse-optimal shape when the primary key is the sorting key: EXPLAIN shows
# PrimaryKey binary-search pruning per batch (probed 2026-07-13), so no custom
# find_each is needed — this spec locks that in.
RSpec.describe "ClickHouse batching" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "batch_probe"
      self.primary_key = "id"

      def self.name = "BatchProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("batch_probe", if_exists: true)
    conn.create_table("batch_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :note, default: ""
    end
    conn.execute("INSERT INTO batch_probe SELECT number, toString(number) FROM numbers(5000)")
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("batch_probe", if_exists: true)
  end

  it "iterates every row through find_each" do
    expect(model.find_each(batch_size: 2000).count).to eq(5000)
  end

  it "walks batches by primary-key ranges, not OFFSET" do
    batch_sql = []
    watcher = ->(event) { batch_sql << event.payload[:sql] if event.payload[:sql].include?("batch_probe`.`id` >") }
    ActiveSupport::Notifications.subscribed(watcher, "sql.active_record") do
      model.find_each(batch_size: 2000) { nil }
    end
    expect(batch_sql.length).to eq(2)
  end

  it "prunes each batch through the sorting key" do
    plan = ActiveRecord::Base.lease_connection.select_all(
      "EXPLAIN indexes = 1 SELECT * FROM batch_probe WHERE id > 1999 ORDER BY id LIMIT 2000"
    ).rows.join("\n")
    expect(plan).to include("binary search")
  end
end
