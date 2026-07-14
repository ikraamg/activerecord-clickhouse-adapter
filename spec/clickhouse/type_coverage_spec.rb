# frozen_string_literal: true

RSpec.describe "ClickHouse type family coverage" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  # Families we deliberately do not cast yet. Expand only with a PLAN.md note.
  let(:documented_unsupported) do
    %w[
      AggregateFunction
      BFloat16
      DateTime32
      Dynamic
      Enum
      IntervalDay
      IntervalHour
      IntervalMicrosecond
      IntervalMillisecond
      IntervalMinute
      IntervalMonth
      IntervalNanosecond
      IntervalQuarter
      IntervalSecond
      IntervalWeek
      IntervalYear
      LineString
      MultiLineString
      MultiPolygon
      Nested
      Object
      Point
      Polygon
      Ring
      Time
      Time64
      Variant
    ]
  end

  let(:cast_supported) do
    %w[
      Array
      Bool
      Date
      Date32
      DateTime
      DateTime64
      Decimal
      Decimal128
      Decimal256
      Decimal32
      Decimal64
      Enum16
      Enum8
      FixedString
      Float32
      Float64
      IPv4
      IPv6
      Int128
      Int16
      Int256
      Int32
      Int64
      Int8
      JSON
      LowCardinality
      Map
      Nothing
      Nullable
      SimpleAggregateFunction
      String
      Tuple
      UInt128
      UInt16
      UInt256
      UInt32
      UInt64
      UInt8
      UUID
    ]
  end

  # Families added after 25.8, the oldest supported server; absent there, uncast here.
  let(:newer_server_families) do
    %w[
      Geometry
      QBit
    ]
  end

  # Families 25.8 still lists that newer servers removed (Object died with the old
  # JSON implementation); kept in documented_unsupported for the 25.8 run.
  let(:retired_server_families) do
    %w[
      Object
    ]
  end

  let(:live_families) do
    connection.select_values(
      "SELECT name FROM system.data_type_families WHERE alias_to = '' ORDER BY name"
    )
  end

  it "has no unaccounted live type families" do
    expect(live_families - cast_supported - documented_unsupported - newer_server_families).to eq([])
  end

  it "does not list a family as both supported and unsupported" do
    expect(cast_supported & (documented_unsupported + newer_server_families)).to eq([])
  end

  it "covers every live non-alias family exactly once" do
    accounted = cast_supported + documented_unsupported + newer_server_families
    expect(accounted.sort).to eq((live_families | newer_server_families | retired_server_families).sort)
  end
end
