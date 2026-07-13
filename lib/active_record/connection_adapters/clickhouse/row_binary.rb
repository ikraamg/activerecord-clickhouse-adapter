# frozen_string_literal: true

require "bigdecimal"
require "date"
require "ipaddr"

require "active_record/connection_adapters/clickhouse/type_parser"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Decodes RowBinaryWithNamesAndTypes bodies: a varint column count, the names,
      # the type strings, then rows of packed values (probed 2026-07-13, PLAN.md §2).
      # Yields the same Ruby values the JSON casters produce, so the cast layer treats
      # both wires identically. Types without a binary decoder raise Undecodable and
      # the connection retries the query on the JSON wire.
      class RowBinary
        Undecodable = Class.new(StandardError) # rubocop:disable Style/EmptyClassDefinition

        INTEGER_FORMATS = {
          "Int8" => ["c", 1], "Int16" => ["s<", 2], "Int32" => ["l<", 4], "Int64" => ["q<", 8],
          "UInt8" => ["C", 1], "UInt16" => ["S<", 2], "UInt32" => ["L<", 4], "UInt64" => ["Q<", 8]
        }.freeze

        # Storage width is decided by precision; the server normalizes every Decimal
        # alias to Decimal(precision, scale) in the type header.
        DECIMAL_BYTES = [[9, 4], [18, 8], [38, 16], [76, 32]].freeze

        UNIX_EPOCH_JULIAN_DAY = Date.new(1970, 1, 1).jd

        def self.decode(body) = new(body).decode

        def initialize(body)
          @body = body
          @position = 0
        end

        def decode
          return [[], [], []] if @body.empty?

          names = Array.new(read_varint) { read_string }
          types = Array.new(names.length) { read_string }
          decoders = types.map { |type| value_decoder(TypeParser.parse(type)) }
          rows = []
          rows << decoders.map(&:call) until end_of_body?
          [names, types, rows]
        end

        private

        def end_of_body? = @position >= @body.bytesize

        def value_decoder(node) # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/AbcSize, Metrics/PerceivedComplexity
          case node.name
          when "Nullable" then nullable_decoder(node)
          when "LowCardinality" then value_decoder(node.args.fetch(0))
          when "SimpleAggregateFunction" then value_decoder(node.args.fetch(1))
          when "Array" then array_decoder(node)
          when "Map" then map_decoder(node)
          when "Tuple" then tuple_decoder(node)
          # output_format_binary_write_json_as_string=1 delivers JSON columns as String.
          when "String", "JSON" then -> { read_string }
          when "FixedString" then -> { read_bytes(node.args.fetch(0)) }
          when "Bool" then -> { read_unsigned(1) != 0 }
          when "Enum8" then enum_decoder(node, 1)
          when "Enum16" then enum_decoder(node, 2)
          when "UUID" then -> { read_uuid }
          when "IPv4" then -> { IPAddr.new_ntoh([read_unsigned(4)].pack("N")) }
          when "IPv6" then -> { IPAddr.new_ntoh(@body.byteslice(advance(16), 16)) }
          when "Date" then -> { Date.jd(UNIX_EPOCH_JULIAN_DAY + read_unsigned(2)) }
          when "Date32" then -> { Date.jd(UNIX_EPOCH_JULIAN_DAY + read_signed(4)) }
          when "DateTime" then -> { Time.at(read_unsigned(4)).utc }
          when "DateTime64" then datetime64_decoder(node)
          when "Float32" then -> { @body.unpack1("e", offset: advance(4)) }
          when "Float64" then -> { @body.unpack1("E", offset: advance(8)) }
          when "Decimal" then decimal_decoder(node)
          when "Int128", "Int256" then -> { read_signed(node.name == "Int128" ? 16 : 32) }
          when "UInt128", "UInt256" then -> { read_unsigned(node.name == "UInt128" ? 16 : 32) }
          when "Nothing" then -> { advance(1) && nil }
          else
            INTEGER_FORMATS.key?(node.name) ? integer_decoder(node) : raise_undecodable(node)
          end
        end

        def raise_undecodable(node)
          raise Undecodable, "no RowBinary decoder for ClickHouse type #{node.name}"
        end

        def integer_decoder(node)
          format, size = INTEGER_FORMATS.fetch(node.name)
          -> { @body.unpack1(format, offset: advance(size)) }
        end

        def nullable_decoder(node)
          inner = value_decoder(node.args.fetch(0))
          -> { read_unsigned(1) == 1 ? nil : inner.call }
        end

        def array_decoder(node)
          inner = value_decoder(node.args.fetch(0))
          -> { Array.new(read_varint) { inner.call } }
        end

        def map_decoder(node)
          key = value_decoder(node.args.fetch(0))
          value = value_decoder(node.args.fetch(1))
          -> { Array.new(read_varint) { [key.call, value.call] }.to_h }
        end

        # Named tuples come back as hashes to match the JSON wire's object shape.
        def tuple_decoder(node)
          if node.args.first.is_a?(Array)
            members = node.args.map { |name, type| [name, value_decoder(type)] }
            -> { members.to_h { |name, decoder| [name, decoder.call] } }
          else
            members = node.args.map { |type| value_decoder(type) }
            -> { members.map(&:call) }
          end
        end

        def enum_decoder(node, size)
          labels = node.args.to_h { |label, number| [number, label] }
          -> { labels.fetch(read_signed(size)) }
        end

        def datetime64_decoder(node)
          divisor = 10**node.args.fetch(0)
          -> { Time.at(Rational(read_signed(8), divisor)).utc }
        end

        def decimal_decoder(node)
          precision, scale = node.args
          size = DECIMAL_BYTES.find { |max_precision, _| precision <= max_precision }.last
          -> { BigDecimal("#{read_signed(size)}e-#{scale}") }
        end

        def read_varint
          result = 0
          shift = 0
          loop do
            byte = @body.getbyte(advance(1))
            result |= (byte & 0x7f) << shift
            return result if byte < 0x80

            shift += 7
          end
        end

        def read_string = read_bytes(read_varint)

        def read_bytes(length)
          @body.byteslice(advance(length), length).force_encoding(Encoding::UTF_8)
        end

        def read_unsigned(size)
          return @body.unpack1(INTEGER_FORMATS.fetch("UInt#{size * 8}").first, offset: advance(size)) if size <= 8

          words = @body.unpack("Q<#{size / 8}", offset: advance(size))
          words.each_with_index.sum { |word, index| word << (64 * index) }
        end

        def read_signed(size)
          return @body.unpack1(INTEGER_FORMATS.fetch("Int#{size * 8}").first, offset: advance(size)) if size <= 8

          value = read_unsigned(size)
          value >= (1 << ((size * 8) - 1)) ? value - (1 << (size * 8)) : value
        end

        # UUIDs travel as two little-endian UInt64 halves (high, then low).
        def read_uuid
          high, low = @body.unpack("Q<2", offset: advance(16))
          format("%<high>016x%<low>016x", high: high, low: low)
            .insert(20, "-").insert(16, "-").insert(12, "-").insert(8, "-")
        end

        def advance(length)
          position = @position
          @position += length
          position
        end
      end
    end
  end
end
