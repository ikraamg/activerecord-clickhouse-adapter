# frozen_string_literal: true

# The read path speaks RowBinaryWithNamesAndTypes: names, then type strings, then
# packed binary rows (probed 2026-07-13, PLAN.md §2). Every family the JSON codec
# handled must decode to the same Ruby value, and undecodable exotics must fall
# back to the JSON wire transparently.
RSpec.describe ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection do
  subject(:connection) { described_class.new(CLICKHOUSE_TEST_CONFIG) }

  after { connection.close }

  def select_value(sql) = connection.execute("SELECT #{sql}").rows.dig(0, 0)

  it "decodes Int64 min" do
    expect(select_value("toInt64(-9223372036854775808)")).to eq(-9_223_372_036_854_775_808)
  end

  it "decodes UInt64 max" do
    expect(select_value("toUInt64('18446744073709551615')")).to eq((2**64) - 1)
  end

  it "decodes Int128 negatives" do
    expect(select_value("toInt128('-170141183460469231731687303715884105728')")).to eq(-(2**127))
  end

  it "decodes UInt256 max" do
    value = select_value(
      "CAST('115792089237316195423570985008687907853269984665640564039457584007913129639935' AS UInt256)"
    )
    expect(value).to eq((2**256) - 1)
  end

  it "decodes Float64" do
    expect(select_value("toFloat64(1.5)")).to eq(1.5)
  end

  it "decodes NaN natively instead of via quoted denormals" do
    expect(select_value("nan")).to be_nan
  end

  it "decodes negative Infinity" do
    expect(select_value("-1/0")).to eq(-Float::INFINITY)
  end

  it "decodes unicode strings" do
    expect(select_value("'héllo\\n'")).to eq("héllo\n")
  end

  it "preserves invalid UTF-8 as raw bytes" do
    expect(select_value("char(0xC3)").bytes).to eq([0xC3])
  end

  it "decodes FixedString with its padding intact" do
    expect(select_value("toFixedString('ab', 4)")).to eq("ab\0\0")
  end

  it "decodes Date" do
    expect(select_value("toDate('2026-01-02')")).to eq(Date.new(2026, 1, 2))
  end

  it "decodes Date32 before the epoch" do
    expect(select_value("toDate32('1900-01-01')")).to eq(Date.new(1900, 1, 1))
  end

  it "decodes DateTime with a column timezone into the correct UTC instant" do
    time = select_value("toDateTime('2024-06-15 12:30:45', 'Asia/Tokyo')")
    expect(time).to eq(Time.utc(2024, 6, 15, 3, 30, 45))
  end

  it "decodes DateTime64 microseconds exactly" do
    time = select_value("toDateTime64('2026-01-02 03:04:05.123456', 6, 'UTC')")
    expect(time).to eq(Time.utc(2026, 1, 2, 3, 4, 5, 123_456))
  end

  it "decodes negative Decimal exactly" do
    expect(select_value("toDecimal32('-1.5', 2)")).to eq(BigDecimal("-1.5"))
  end

  it "decodes Decimal128 beyond Float precision exactly" do
    value = select_value("toDecimal128('12345678901234567890.1234567891', 10)")
    expect(value).to eq(BigDecimal("12345678901234567890.1234567891"))
  end

  it "decodes Decimal256 exactly" do
    expect(select_value("toDecimal256('-1.5', 40)")).to eq(BigDecimal("-1.5"))
  end

  it "decodes UUID into its canonical string form" do
    expect(select_value("toUUID('61f0c404-5cb3-11e7-907b-a6006ad3dba0')"))
      .to eq("61f0c404-5cb3-11e7-907b-a6006ad3dba0")
  end

  it "decodes Enum8 into its label" do
    expect(select_value("CAST('a', 'Enum8(''a'' = 1, ''b'' = 2)')")).to eq("a")
  end

  it "decodes Enum16 into its label" do
    expect(select_value("CAST('b', 'Enum16(''a'' = 1, ''b'' = 300)')")).to eq("b")
  end

  it "decodes Bool" do
    expect(connection.execute("SELECT true AS t, false AS f").rows).to eq([[true, false]])
  end

  it "decodes IPv4" do
    expect(select_value("toIPv4('1.2.3.4')")).to eq(IPAddr.new("1.2.3.4"))
  end

  it "decodes IPv6" do
    expect(select_value("toIPv6('2001:db8::1')")).to eq(IPAddr.new("2001:db8::1"))
  end

  it "decodes NULL under Nullable" do
    expect(connection.execute("SELECT CAST(NULL, 'Nullable(UInt64)') AS v, 42 AS w").rows).to eq([[nil, 42]])
  end

  it "decodes present values under Nullable" do
    expect(select_value("CAST(7, 'Nullable(UInt64)')")).to eq(7)
  end

  it "decodes nested arrays" do
    expect(select_value("[[1], [2, 3]]")).to eq([[1], [2, 3]])
  end

  it "decodes arrays of nullables" do
    expect(select_value("[1, NULL]")).to eq([1, nil])
  end

  it "decodes Map into a Hash" do
    expect(select_value("map('a', 1, 'b', 2)")).to eq({ "a" => 1, "b" => 2 })
  end

  it "decodes unnamed Tuple into an Array" do
    expect(select_value("tuple(1, 'x')")).to eq([1, "x"])
  end

  it "decodes named Tuple into a Hash" do
    expect(select_value("CAST(tuple(1, 'x'), 'Tuple(n UInt8, s String)')")).to eq({ "n" => 1, "s" => "x" })
  end

  it "decodes LowCardinality as its inner type" do
    expect(select_value("toLowCardinality('hey')")).to eq("hey")
  end

  it "decodes SimpleAggregateFunction as its value type" do
    sql = "SELECT maxSimpleState(number) AS v FROM numbers(3) FORMAT RowBinaryWithNamesAndTypes"
    expect(connection.execute(sql).rows).to eq([[2]])
  end

  it "delivers JSON columns as strings for the caster layer" do
    expect(select_value(%q(CAST('{"k":1}', 'JSON')))).to eq('{"k":1}')
  end

  it "returns an empty result for statements without a body" do
    expect(connection.execute("SET max_threads = 1").columns).to eq([])
  end

  it "survives a large gzip-compressed binary body" do
    expect(connection.execute("SELECT number FROM numbers(100000)").rows.last).to eq([99_999])
  end

  context "when a column type has no binary decoder" do
    subject(:result) { connection.execute("SELECT uniqState(toUInt8(1)) AS state") }

    it "falls back to the JSON wire transparently" do
      expect(result.types).to eq(["AggregateFunction(uniq, UInt8)"])
    end

    it "still delivers the row" do
      expect(result.rows.length).to eq(1)
    end
  end

  context "when configured with select_format: :json" do
    subject(:connection) { described_class.new(CLICKHOUSE_TEST_CONFIG.merge(select_format: :json)) }

    it "serves results from the JSON wire" do
      expect(connection.execute("SELECT toInt64(42) AS v").rows).to eq([[42]])
    end
  end
end
