# frozen_string_literal: true

RSpec.describe "ClickHouse quoting" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "escapes single quotes in strings" do
    expect(connection.quote("O'Brien")).to eq("'O\\'Brien'")
  end

  it "escapes backslashes in strings" do
    expect(connection.quote("a\\b")).to eq("'a\\\\b'")
  end

  it "quotes identifiers with backticks" do
    expect(connection.quote_column_name("order")).to eq("`order`")
  end

  it "quotes nil as NULL" do
    expect(connection.quote(nil)).to eq("NULL")
  end

  it "quotes booleans as ClickHouse literals" do
    expect(connection.quote(true)).to eq("true")
    expect(connection.quote(false)).to eq("false")
  end

  it "quotes arrays as ClickHouse array literals" do
    expect(connection.quote([1, "a"])).to eq("[1, 'a']")
  end

  it "quotes hashes as ClickHouse map literals" do
    expect(connection.quote("k" => 1)).to eq("{'k': 1}")
  end

  it "round-trips a quoted injection payload via SELECT" do
    sql = "SELECT #{connection.quote("'; DROP TABLE users; --")}"
    expect(connection.select_value(sql)).to eq("'; DROP TABLE users; --")
  end

  it "round-trips unicode through quoting" do
    expect(connection.select_value("SELECT #{connection.quote("héllo 👋")}")).to eq("héllo 👋")
  end
end
