# frozen_string_literal: true

# Rails fixtures (and the compat harness) load through insert_fixtures_set. The abstract
# implementation wraps bare DELETEs in a transaction; ClickHouse has neither, so the
# adapter reimplements it as TRUNCATE + batched INSERTs.
RSpec.describe "ClickHouse fixture loading" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    require "active_record/fixtures"
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("fixture_probe", if_exists: true)
    conn.create_table("fixture_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :name
      t.integer :rank, default: 5
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("fixture_probe", if_exists: true)
  end

  before do
    connection.execute("INSERT INTO fixture_probe VALUES (99, 'stale', 1)")
  end

  it "replaces existing rows with the fixture set" do
    connection.insert_fixtures_set(
      { "fixture_probe" => [{ "id" => 1, "name" => "alpha" }, { "id" => 2, "name" => "beta", "rank" => 2 }] },
      %w[fixture_probe]
    )
    expect(connection.select_value("SELECT count() FROM fixture_probe")).to eq(2)
  end

  it "fills omitted columns with their table defaults" do
    connection.insert_fixtures_set({ "fixture_probe" => [{ "id" => 1, "name" => "alpha" }] }, %w[fixture_probe])
    expect(connection.select_value("SELECT rank FROM fixture_probe WHERE id = 1")).to eq(5)
  end

  it "empties tables that get no fixtures" do
    connection.insert_fixtures_set({}, %w[fixture_probe])
    expect(connection.select_value("SELECT count() FROM fixture_probe")).to eq(0)
  end
end
