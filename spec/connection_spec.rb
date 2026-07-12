# frozen_string_literal: true

RSpec.describe "ClickHouse connection", :aggregate_failures do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "identifies itself by adapter name" do
    expect(connection.adapter_name).to eq("ClickHouse")
  end

  it "answers a live SELECT with a typed Ruby integer" do
    expect(connection.select_value("SELECT 1")).to eq(1)
  end

  it "reports the live server as active" do
    expect(connection).to be_active
  end

  it "exposes the real server version" do
    expect(connection.database_version.to_s).to match(/\A\d+\.\d+/)
  end
end
