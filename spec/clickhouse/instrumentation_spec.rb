# frozen_string_literal: true

RSpec.describe "ClickHouse instrumentation" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("instr_probe", if_exists: true)
    conn.create_table("instr_probe", order: "n") { |t| t.integer :n, limit: 8 }
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("instr_probe", if_exists: true)
  end

  before do
    connection.execute("TRUNCATE TABLE instr_probe")
    connection.execute("INSERT INTO instr_probe SELECT number FROM numbers(1000)")
  end

  def payload_for(&query)
    captured = nil
    callback = ->(event) { captured = event.payload if event.payload[:clickhouse] }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &query)
    captured
  end

  it "reports rows read by the server on selects" do
    payload = payload_for { connection.select_value("SELECT sum(n) FROM instr_probe") }
    expect(payload[:clickhouse][:read_rows]).to eq(1000)
  end

  it "reports rows written on inserts" do
    payload = payload_for { connection.execute("INSERT INTO instr_probe VALUES (1000)") }
    expect(payload[:clickhouse][:written_rows]).to eq(1)
  end

  it "reports server-side elapsed time in nanoseconds" do
    payload = payload_for { connection.select_value("SELECT count() FROM instr_probe") }
    expect(payload[:clickhouse][:elapsed_ns]).to be_positive
  end

  it "carries the server query id" do
    payload = payload_for { connection.select_value("SELECT 1") }
    expect(payload[:clickhouse][:query_id]).to match(/\A[0-9a-f-]{36}\z/)
  end
end
