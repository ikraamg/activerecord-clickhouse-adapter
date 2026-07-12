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

  it "leaves a ? inside a string literal alone" do
    expect(connection.select_value("SELECT concat('what?', ?)", nil, ["!"])).to eq("what?!")
  end

  it "leaves a ? inside a doubled-quote-escaped literal alone" do
    expect(connection.select_value("SELECT concat('it''s?', ?)", nil, ["ok"])).to eq("it's?ok")
  end

  it "leaves a ? inside a backslash-escaped literal alone" do
    expect(connection.select_value("SELECT concat('don\\'t?', ?)", nil, ["ok"])).to eq("don't?ok")
  end

  it "leaves a ? inside a backtick identifier alone" do
    expect(connection.select_one("SELECT ? AS `odd?name`", nil, [1])).to eq("odd?name" => 1)
  end

  # Probed 2026-07-12: the server parses String params in its escaped format — a raw
  # newline or tab raises BAD_QUERY_PARAMETER (code 457); backslash sequences round-trip.
  it "round-trips a string containing newlines" do
    expect(connection.select_value("SELECT ?", nil, ["---\nfoo: bar\n"])).to eq("---\nfoo: bar\n")
  end

  it "round-trips a string containing tabs" do
    expect(connection.select_value("SELECT ?", nil, ["a\tb"])).to eq("a\tb")
  end

  it "round-trips a string containing literal backslash-n" do
    expect(connection.select_value("SELECT ?", nil, ['a\nb'])).to eq('a\nb')
  end

  it "round-trips a string containing backslashes and quotes" do
    expect(connection.select_value("SELECT ?", nil, ["it's a \\ backslash"])).to eq("it's a \\ backslash")
  end

  it "round-trips an integer beyond UInt64 without wrapping" do
    expect(connection.select_value("SELECT ?", nil, [2**70])).to eq(2**70)
  end

  it "round-trips Int64 minimum" do
    expect(connection.select_value("SELECT ?", nil, [-(2**63)])).to eq(-(2**63))
  end

  it "round-trips UInt256 maximum" do
    expect(connection.select_value("SELECT ?", nil, [(2**256) - 1])).to eq((2**256) - 1)
  end

  it "raises instead of wrapping an integer beyond 256 bits" do
    expect { connection.select_value("SELECT ?", nil, [2**300]) }
      .to raise_error(ActiveRecord::StatementInvalid, /out of range/)
  end
end
