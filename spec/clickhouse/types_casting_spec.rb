# frozen_string_literal: true

RSpec.describe "ClickHouse type casting", :aggregate_failures do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  def select_value(sql) = connection.select_value(sql)
  def select_row(sql) = connection.select_one(sql)

  it "casts UInt8 integers" do
    expect(select_value("SELECT CAST(255 AS UInt8)")).to eq(255)
  end

  it "casts Int8 min/max" do
    expect(select_value("SELECT CAST(-128 AS Int8)")).to eq(-128)
    expect(select_value("SELECT CAST(127 AS Int8)")).to eq(127)
  end

  it "preserves Int64 above the JS safe-integer limit as Integer" do
    expect(select_value("SELECT CAST(9007199254740993 AS Int64)")).to eq(9_007_199_254_740_993)
  end

  it "preserves UInt256 as Integer" do
    # Numeric literals this large are parsed as Float by ClickHouse; pass as String.
    value = select_value(
      "SELECT CAST('115792089237316195423570985008687907853269984665640564039457584007913129639935' AS UInt256)"
    )
    expect(value).to eq((2**256) - 1)
  end

  it "casts Float64 from BigDecimal wire values to Float" do
    expect(select_value("SELECT toFloat64(1.5)")).to eq(1.5)
    expect(select_value("SELECT toFloat64(1.5)")).to be_a(Float)
  end

  it "round-trips Decimal(38, 10) as exact BigDecimal" do
    sql = "SELECT toDecimal128('12345678901234567890.1234567891', 10)"
    expect(select_value(sql)).to eq(BigDecimal("12345678901234567890.1234567891"))
  end

  it "casts Bool" do
    expect(select_value("SELECT CAST(1 AS Bool)")).to be(true)
    expect(select_value("SELECT CAST(0 AS Bool)")).to be(false)
  end

  it "casts String unicode and quotes" do
    expect(select_value("SELECT 'héllo\\n'")).to eq("héllo\n")
  end

  it "casts Date and Date32 boundaries" do
    expect(select_value("SELECT toDate('1970-01-01')")).to eq(Date.new(1970, 1, 1))
    expect(select_value("SELECT toDate32('1900-01-01')")).to eq(Date.new(1900, 1, 1))
    expect(select_value("SELECT toDate32('2299-12-31')")).to eq(Date.new(2299, 12, 31))
  end

  it "casts DateTime64 with column timezone into the correct UTC instant" do
    time = select_value("SELECT toDateTime('2024-06-15 12:30:45', 'Asia/Tokyo')")

    expect(time).to be_a(Time)
    expect(time.utc).to eq(Time.utc(2024, 6, 15, 3, 30, 45))
  end

  it "casts DateTime64 fractional precision" do
    time = select_value("SELECT toDateTime64('2024-06-15 12:30:45.123456789', 9, 'UTC')")

    expect(time.utc.strftime("%Y-%m-%d %H:%M:%S.%N")).to eq("2024-06-15 12:30:45.123456789")
  end

  it "casts UUID as canonical string" do
    expect(select_value("SELECT toUUID('550e8400-e29b-41d4-a716-446655440000')"))
      .to eq("550e8400-e29b-41d4-a716-446655440000")
  end

  it "casts IPv4 and IPv6 as IPAddr" do
    expect(select_value("SELECT toIPv4('192.168.1.1')")).to eq(IPAddr.new("192.168.1.1"))
    expect(select_value("SELECT toIPv6('2001:db8::1')")).to eq(IPAddr.new("2001:db8::1"))
  end

  it "casts Enum labels including negatives on the type side" do
    expect(select_value("SELECT CAST('c' AS Enum8('a\\'b' = 1, 'c' = -128))")).to eq("c")
  end

  it "casts Nullable nil and Nested nulls in arrays" do
    expect(select_value("SELECT CAST(NULL AS Nullable(Int64))")).to be_nil
    expect(select_value("SELECT [1, NULL]")).to eq([1, nil])
  end

  it "casts Map values" do
    expect(select_value("SELECT map('a', toUInt8(1))")).to eq("a" => 1)
  end

  it "casts positional Tuple as Array" do
    expect(select_value("SELECT CAST((1, 'x') AS Tuple(UInt8, String))")).to eq([1, "x"])
  end

  it "casts named Tuple as Hash" do
    expect(select_value("SELECT CAST((1, 'x') AS Tuple(n UInt8, s String))")).to eq("n" => 1, "s" => "x")
  end

  it "casts LowCardinality transparently" do
    expect(select_value("SELECT CAST('hi' AS LowCardinality(String))")).to eq("hi")
  end

  it "casts Nullable(Nothing) bare NULL to nil" do
    expect(select_value("SELECT NULL")).to be_nil
  end

  it "casts empty Array and Map" do
    expect(select_value("SELECT emptyArrayUInt8()")).to eq([])
    expect(select_value("SELECT map()")).to eq({})
  end
end
