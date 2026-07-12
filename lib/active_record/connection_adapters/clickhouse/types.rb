# frozen_string_literal: true

require "bigdecimal"
require "date"
require "ipaddr"
require "json"
require "singleton"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Builds eager value casters from ClickHouse type AST nodes.
      module Types
        module_function

        def caster_for(type_string) = build(TypeParser.parse(type_string))

        # ActiveModel type for schema introspection (Column#type); wrappers unwrap.
        def active_record_cast_type(type_string) = ar_cast_type(TypeParser.parse(type_string))

        def ar_cast_type(node) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
          case node.name
          when "Nullable", "LowCardinality" then ar_cast_type(node.args.fetch(0))
          when "SimpleAggregateFunction" then ar_cast_type(node.args.fetch(1))
          when /\AU?Int(8|16|32|64|128|256)\z/ then ActiveModel::Type::Integer.new(limit: Regexp.last_match(1).to_i / 8)
          when "Float32", "Float64" then ActiveModel::Type::Float.new
          when "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256"
            precision, scale = node.args.grep(Integer)
            ActiveModel::Type::Decimal.new(precision: precision, scale: scale)
          when "Date", "Date32" then ActiveModel::Type::Date.new
          when "DateTime" then ActiveModel::Type::DateTime.new
          when "DateTime64" then ActiveModel::Type::DateTime.new(precision: node.args.first)
          when "Bool" then ActiveModel::Type::Boolean.new
          when "String", "FixedString", "Enum8", "Enum16", "UUID", "IPv4", "IPv6" then ActiveModel::Type::String.new
          when "JSON" then ActiveRecord::Type::Json.new
          else ActiveModel::Type::Value.new
          end
        end

        def build(node) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
          case node.name
          when "Nullable" then Nullable.new(build(node.args.fetch(0)))
          when "LowCardinality" then build(node.args.fetch(0))
          when "Array" then ArrayCaster.new(build(node.args.fetch(0)))
          when "Map" then MapCaster.new(build(node.args.fetch(0)), build(node.args.fetch(1)))
          when "Tuple" then tuple_caster(node.args)
          when "SimpleAggregateFunction" then build(node.args.fetch(1))
          when "AggregateFunction" then Passthrough.instance
          when "Bool" then BoolCaster.instance
          when "String", "FixedString", "UUID", "Enum8", "Enum16" then StringCaster.instance
          when "JSON" then JsonCaster.instance
          when "Nothing" then NullCaster.instance
          when "Date", "Date32" then DateCaster.instance
          when "DateTime" then DateTimeCaster.new(node.args[0])
          when "DateTime64" then DateTimeCaster.new(node.args[1])
          when "IPv4", "IPv6" then IpCaster.instance
          when "Float32", "Float64" then FloatCaster.instance
          when "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256" then DecimalCaster.instance
          when /\A(?:UInt|Int)(?:8|16|32|64|128|256)\z/ then IntegerCaster.instance
          else
            raise ArgumentError, "unsupported ClickHouse type family: #{node.name}"
          end
        end

        def tuple_caster(args)
          if args.first.is_a?(Array)
            NamedTupleCaster.new(args.to_h { |name, type_node| [name, build(type_node)] })
          else
            PositionalTupleCaster.new(args.map { |type_node| build(type_node) })
          end
        end
        private_class_method :tuple_caster

        class Passthrough
          include Singleton

          def cast(value) = value
        end

        class NullCaster
          include Singleton

          def cast(_value) = nil
        end

        class Nullable
          def initialize(inner) = @inner = inner
          def cast(value) = value.nil? ? nil : @inner.cast(value)
        end

        class IntegerCaster
          include Singleton

          def cast(value) = Integer(value)
        end

        class FloatCaster
          include Singleton

          # quote_denormals=1 delivers these as strings; anything else must be numeric.
          DENORMAL_VALUES = {
            "nan" => Float::NAN, "inf" => Float::INFINITY,
            "+inf" => Float::INFINITY, "-inf" => -Float::INFINITY
          }.freeze

          def cast(value) = DENORMAL_VALUES.fetch(value) { Float(value) }
        end

        class DecimalCaster
          include Singleton

          def cast(value) = value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end

        class StringCaster
          include Singleton

          def cast(value) = value.to_s
        end

        class BoolCaster
          include Singleton

          def cast(value) = [true, 1, "1", "true"].include?(value)
        end

        class DateCaster
          include Singleton

          def cast(value) = value.is_a?(Date) ? value : Date.parse(value.to_s)
        end

        class DateTimeCaster
          def initialize(time_zone) = @time_zone = time_zone

          def cast(value)
            return value if value.is_a?(Time)

            zone = @time_zone ? ActiveSupport::TimeZone[@time_zone] : default_zone
            raise ArgumentError, "unknown time zone #{@time_zone.inspect}" if @time_zone && zone.nil?

            zone.parse(value.to_s)
          end

          private

          def default_zone
            if ActiveRecord.default_timezone == :local && ::Time.zone
              ::Time.zone
            else
              ActiveSupport::TimeZone["UTC"]
            end
          end
        end

        class IpCaster
          include Singleton

          def cast(value) = value.is_a?(IPAddr) ? value : IPAddr.new(value.to_s)
        end

        class JsonCaster
          include Singleton

          def cast(value)
            case value
            when String then JSON.parse(value)
            else value
            end
          end
        end

        class ArrayCaster
          def initialize(inner) = @inner = inner
          def cast(value) = Array(value).map { |item| @inner.cast(item) }
        end

        class MapCaster
          def initialize(key_caster, value_caster)
            @key_caster = key_caster
            @value_caster = value_caster
          end

          def cast(value)
            value.to_h { |key, item| [@key_caster.cast(key), @value_caster.cast(item)] }
          end
        end

        class PositionalTupleCaster
          def initialize(casters) = @casters = casters

          def cast(value)
            Array(value).each_with_index.map { |item, index| @casters.fetch(index).cast(item) }
          end
        end

        class NamedTupleCaster
          def initialize(casters) = @casters = casters

          def cast(value)
            value.to_h do |key, item|
              name = key.to_s
              [name, @casters.fetch(name).cast(item)]
            end
          end
        end
      end
    end
  end
end
