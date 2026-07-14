# frozen_string_literal: true

# A `cluster:` config key stamps schema DDL with ON CLUSTER so every replica sees
# the change. The compose file runs an embedded Keeper because distributed DDL
# needs a coordination layer even on the stock single-replica `default` cluster
# (NO_ELEMENTS_IN_CONFIG without one — probed 2026-07-14).
RSpec.describe "ON CLUSTER DDL" do
  subject(:adapter) do
    ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(CLICKHOUSE_TEST_CONFIG.merge(cluster: "default"))
  end

  after do
    adapter.execute("DROP TABLE IF EXISTS oncluster_probe ON CLUSTER `default`")
    adapter.disconnect!
  end

  it "reports the configured cluster" do
    expect(adapter.cluster).to eq("default")
  end

  it "creates tables through the distributed DDL queue" do
    adapter.create_table("oncluster_probe", order: "id") { |t| t.integer :id, limit: 8 }
    expect(adapter.table_exists?("oncluster_probe")).to be(true)
  end

  it "records the CREATE in the distributed DDL log" do
    adapter.create_table("oncluster_probe", order: "id") { |t| t.integer :id, limit: 8 }
    queued = adapter.select_value(<<~SQL.squish)
      SELECT count() FROM system.distributed_ddl_queue WHERE query LIKE '%oncluster_probe%'
    SQL
    expect(queued.to_i).to be > 0
  end

  it "alters tables on the cluster" do
    adapter.create_table("oncluster_probe", order: "id") { |t| t.integer :id, limit: 8 }
    adapter.add_column("oncluster_probe", :label, :string, null: true)
    expect(adapter.column_exists?("oncluster_probe", :label)).to be(true)
  end

  it "changes column defaults on the cluster" do
    adapter.create_table("oncluster_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label
    end
    adapter.change_column_default("oncluster_probe", :label, "unnamed")
    expect(adapter.columns("oncluster_probe").find { |c| c.name == "label" }.default).to eq("unnamed")
  end

  it "removes columns on the cluster" do
    adapter.create_table("oncluster_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label
    end
    adapter.remove_column("oncluster_probe", :label)
    expect(adapter.column_exists?("oncluster_probe", :label)).to be(false)
  end

  it "drops tables on the cluster" do
    adapter.create_table("oncluster_probe", order: "id") { |t| t.integer :id, limit: 8 }
    adapter.drop_table("oncluster_probe")
    expect(adapter.table_exists?("oncluster_probe")).to be(false)
  end

  it "renames tables on the cluster" do
    adapter.create_table("oncluster_probe", order: "id") { |t| t.integer :id, limit: 8 }
    adapter.rename_table("oncluster_probe", "oncluster_renamed")
    expect(adapter.table_exists?("oncluster_renamed")).to be(true)
  ensure
    adapter.execute("DROP TABLE IF EXISTS oncluster_renamed ON CLUSTER `default`")
  end

  it "leaves DDL untouched when no cluster is configured" do
    plain = ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(CLICKHOUSE_TEST_CONFIG)
    expect(plain.cluster).to be_nil
  ensure
    plain.disconnect!
  end
end
