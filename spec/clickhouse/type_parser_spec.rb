# frozen_string_literal: true

RSpec.describe ActiveRecord::ConnectionAdapters::ClickHouse::TypeParser do
  subject(:parse) { described_class.parse(type_string) }

  def node(name, *args) = described_class::Node.new(name, args)

  context "with bare scalar families" do
    {
      "UInt8" => "UInt8",
      "Int64" => "Int64",
      "Float32" => "Float32",
      "String" => "String",
      "Date" => "Date",
      "Date32" => "Date32",
      "UUID" => "UUID",
      "Bool" => "Bool",
      "IPv4" => "IPv4",
      "IPv6" => "IPv6",
      "Nothing" => "Nothing",
      "JSON" => "JSON"
    }.each do |type_string, name|
      context "when parsing #{type_string}" do
        let(:type_string) { type_string }

        it "returns a leaf node" do
          expect(parse).to eq(node(name))
        end
      end
    end
  end

  context "with parameterized scalars" do
    {
      "FixedString(16)" => ["FixedString", 16],
      "Decimal(38, 10)" => ["Decimal", 38, 10],
      "Decimal256(10)" => ["Decimal256", 10],
      "DateTime('UTC')" => %w[DateTime UTC],
      "DateTime64(3)" => ["DateTime64", 3],
      "DateTime64(3, 'Asia/Tokyo')" => ["DateTime64", 3, "Asia/Tokyo"]
    }.each do |type_string, (name, *args)|
      context "when parsing #{type_string}" do
        let(:type_string) { type_string }

        it "captures parameters" do
          expect(parse).to eq(node(name, *args))
        end
      end
    end
  end

  context "with wrappers and nesting" do
    let(:type_string) { "LowCardinality(Nullable(String))" }

    it "builds a nested AST" do
      expect(parse).to eq(node("LowCardinality", node("Nullable", node("String"))))
    end
  end

  context "with Array and Map" do
    let(:type_string) { "Array(Map(String, Tuple(UInt8, Nullable(Date))))" }
    let(:expected) do
      node(
        "Array",
        node(
          "Map",
          node("String"),
          node("Tuple", node("UInt8"), node("Nullable", node("Date")))
        )
      )
    end

    it "parses composite nesting" do
      expect(parse).to eq(expected)
    end
  end

  context "with positional Tuple" do
    let(:type_string) { "Tuple(UInt8, String)" }

    it "keeps elements as type nodes" do
      expect(parse).to eq(node("Tuple", node("UInt8"), node("String")))
    end
  end

  context "with named Tuple including whitespace" do
    # Live toTypeName can pretty-print named tuples with newlines (verified 2026-07-12).
    let(:type_string) { "Tuple(\n    a UInt8,\n    b String)" }

    it "parses named elements as name/type pairs" do
      expect(parse).to eq(
        node("Tuple", ["a", node("UInt8")], ["b", node("String")])
      )
    end
  end

  context "with Enum8 including escaped quotes and negatives" do
    # Live server emits Enum8('c' = -128, 'a\'b' = 1) for Enum8('a\'b' = 1, 'c' = -128).
    let(:type_string) { "Enum8('c' = -128, 'a\\'b' = 1)" }

    it "captures string/int mappings with unescaped names" do
      expect(parse).to eq(node("Enum8", ["c", -128], ["a'b", 1]))
    end
  end

  context "with SimpleAggregateFunction" do
    let(:type_string) { "SimpleAggregateFunction(sum, UInt64)" }

    it "keeps the function name and underlying type" do
      expect(parse).to eq(node("SimpleAggregateFunction", "sum", node("UInt64")))
    end
  end

  context "with AggregateFunction" do
    let(:type_string) { "AggregateFunction(sum, UInt64)" }

    it "parses for opaque passthrough later" do
      expect(parse).to eq(node("AggregateFunction", "sum", node("UInt64")))
    end
  end

  context "with a parametric AggregateFunction" do
    let(:type_string) { "AggregateFunction(quantile(0.95), Int64)" }

    it "keeps the parameters inside the function label" do
      expect(parse).to eq(node("AggregateFunction", "quantile(0.95)", node("Int64")))
    end
  end

  context "with a multi-parameter AggregateFunction" do
    let(:type_string) { "AggregateFunction(quantiles(0.5, 0.9), Int64)" }

    it "keeps all parameters in the label verbatim" do
      expect(parse).to eq(node("AggregateFunction", "quantiles(0.5, 0.9)", node("Int64")))
    end
  end

  context "when input is malformed" do
    {
      "" => "empty type string",
      "Nullable(" => "unclosed parameter list",
      "Decimal(38," => "trailing comma in parameters",
      "Enum8('a' = )" => "missing enum value",
      "UInt8 leftover" => "trailing input after type"
    }.each do |type_string, reason|
      context "when #{reason}" do
        subject(:parse!) { described_class.parse(type_string) }

        let(:type_string) { type_string }

        it "raises TypeParser::Error" do
          expect { parse! }.to raise_error(described_class::Error)
        end
      end
    end
  end
end
