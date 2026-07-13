# frozen_string_literal: true

# Bulk ingestion without materializing the batch: rows stream to the server as a
# chunked JSONCompactEachRow POST, so an Enumerator::Lazy of millions of rows never
# holds more than one HTTP chunk in memory.
RSpec.describe "ClickHouse insert_stream" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("stream_events", if_exists: true)
    conn.create_table("stream_events", id: false, order: "device_id") do |t|
      t.integer :device_id, limit: 8, null: false
      t.datetime :seen_at, precision: 6
      t.decimal :amount, precision: 18, scale: 6
      t.string :label, null: true
    end
  end

  after(:all) { ActiveRecord::Base.lease_connection.drop_table("stream_events", if_exists: true) }

  before { connection.execute("TRUNCATE TABLE stream_events") }

  let(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "stream_events"

      def self.name = "StreamEvent"
    end
  end

  it "returns the number of rows written" do
    rows = [{ device_id: 1, label: "a" }, { device_id: 2, label: "b" }]
    expect(connection.insert_stream("stream_events", rows)).to eq(2)
  end

  it "streams a lazy enumerator without materializing it" do
    rows = (1..50_000).lazy.map { |n| { device_id: n, label: "bulk" } }
    connection.insert_stream("stream_events", rows)
    expect(connection.select_value("SELECT count() FROM stream_events")).to eq(50_000)
  end

  it "round-trips times, decimals and nils through the stream" do
    seen_at = Time.utc(2026, 1, 2, 3, 4, 5, 123_456)
    connection.insert_stream(
      "stream_events",
      [{ device_id: 7, seen_at: seen_at, amount: BigDecimal("-12345.654321"), label: nil }]
    )
    row = connection.select_one("SELECT seen_at, amount, label FROM stream_events")
    expect(row).to eq("seen_at" => seen_at, "amount" => BigDecimal("-12345.654321"), "label" => nil)
  end

  it "raises the adapter's translated error for a bad column" do
    expect { connection.insert_stream("stream_events", [{ nope: 1 }]) }
      .to raise_error(ActiveRecord::StatementInvalid)
  end

  it "rejects an empty batch upfront" do
    expect { connection.insert_stream("stream_events", []) }
      .to raise_error(ArgumentError, /no rows/)
  end

  it "is exposed on models with the ClickHouse querying surface" do
    model.insert_stream([{ device_id: 9, label: "model" }])
    expect(model.where(label: "model").count).to eq(1)
  end

  it "reports written rows through the sql.active_record notification" do
    payloads = []
    callback = ->(event) { payloads << event.payload if event.payload[:sql].include?("stream_events") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      connection.insert_stream("stream_events", [{ device_id: 3, label: "note" }])
    end
    expect(payloads.last[:clickhouse][:written_rows]).to eq(1)
  end
end
