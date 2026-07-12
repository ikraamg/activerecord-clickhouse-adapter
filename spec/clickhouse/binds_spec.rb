# frozen_string_literal: true

RSpec.describe "ClickHouse server-side binds" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "binds an integer through select_value" do
    expect(connection.select_value("SELECT ? + 1", nil, [41])).to eq(42)
  end

  it "does not interpolate an injection payload into SQL structure" do
    payload = "'; DROP TABLE users; --"
    expect(connection.select_value("SELECT ?", nil, [payload])).to eq(payload)
  end

  it "binds a string and an integer together" do
    row = connection.select_one("SELECT ? AS label, ? + 1 AS n", nil, ["ok", 41])
    expect(row).to eq("label" => "ok", "n" => 42)
  end
end
