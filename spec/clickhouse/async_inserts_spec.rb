# frozen_string_literal: true

# High-throughput ingestion: async_insert batches many small INSERTs server-side.
# The adapter exposes it as connection config; wait_for_async_insert stays 1 by
# default so an acked insert is a durable insert (fire-and-forget loses data on a
# server crash — opt out explicitly with wait_for_async_insert: 0).
RSpec.describe "ClickHouse async inserts" do
  subject(:async_connection) do
    ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection.new(
      CLICKHOUSE_TEST_CONFIG.except(:adapter).merge(async_insert: true)
    )
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("async_probe", if_exists: true)
    conn.create_table("async_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :note, default: ""
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("async_probe", if_exists: true)
  end

  after { async_connection.close }

  it "sends async_insert to the server" do
    expect(async_connection.execute("SELECT getSetting('async_insert')").rows).to eq([[true]])
  end

  it "waits for the flush by default, so an acked insert is readable" do
    async_connection.execute("INSERT INTO async_probe (id, note) VALUES (1, 'queued')")
    expect(async_connection.execute("SELECT count() FROM async_probe WHERE id = 1").rows).to eq([[1]])
  end

  it "keeps async_insert off without the config" do
    plain = ActiveRecord::Base.lease_connection
    expect(plain.select_value("SELECT getSetting('async_insert')")).to be(false)
  end
end
