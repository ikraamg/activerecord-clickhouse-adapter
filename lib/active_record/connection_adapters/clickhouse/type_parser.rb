# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Recursive-descent parser for ClickHouse type strings from
      # JSONCompactEachRowWithNamesAndTypes. Structure only — no regex nesting.
      class TypeParser
        Error = Class.new(ArgumentError) # rubocop:disable Style/EmptyClassDefinition
        Node = Data.define(:name, :args)

        def self.parse(type_string) = new(type_string).parse

        def initialize(source)
          @source = source.to_s
          @position = 0
        end

        def parse
          raise Error, "empty type string" if @source.strip.empty?

          node = parse_type
          skip_whitespace
          raise Error, "trailing input after type" unless eof?

          node
        end

        private

        def parse_type = parse_type_with_name(parse_identifier)

        def parse_type_with_name(name) # rubocop:disable Metrics/MethodLength
          return Node.new(name, []) unless consume("(")

          args = case name
                 when "Enum8", "Enum16" then parse_enum_args
                 when "Tuple" then parse_tuple_args
                 when "SimpleAggregateFunction", "AggregateFunction" then parse_aggregate_args
                 when "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256",
                      "FixedString", "DateTime", "DateTime64" then parse_literal_args
                 else parse_type_args
                 end
          expect(")")
          Node.new(name, args)
        end

        def parse_type_args = parse_comma_separated { parse_type }

        def parse_literal_args = parse_comma_separated { parse_literal }

        def parse_enum_args = parse_comma_separated { parse_enum_mapping }

        def parse_aggregate_args
          function_name = parse_aggregate_function_label
          expect(",")
          [function_name, *parse_type_args]
        end

        # Parametric combinators (quantile(0.95), topK(10)) carry parameters in the
        # function name itself; the raw balanced-paren text stays in the label. String
        # parameters containing parens would break this — none exist in practice.
        def parse_aggregate_function_label
          name = parse_identifier
          skip_whitespace
          return name unless peek("(")

          "#{name}#{consume_balanced_parens}"
        end

        def consume_balanced_parens
          start = @position
          depth = 0
          loop do
            char = @source[@position] or raise Error, "unterminated aggregate function parameters"
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            @position += 1
            break if depth.zero?
          end
          @source[start...@position]
        end

        def parse_tuple_args
          return [] if peek(")")

          parse_comma_separated { parse_tuple_element }
        end

        def parse_tuple_element
          first = parse_identifier
          skip_whitespace

          if identifier_start?
            [first, parse_type]
          else
            parse_type_with_name(first)
          end
        end

        def parse_enum_mapping
          label = parse_quoted_string
          expect("=")
          [label, parse_signed_integer]
        end

        def parse_literal
          skip_whitespace
          return parse_quoted_string if peek("'")
          return parse_signed_integer if digit? || peek("-")

          raise Error, "expected literal at position #{@position}"
        end

        def parse_comma_separated
          skip_whitespace
          return [] if peek(")")

          values = [yield]
          while consume(",")
            skip_whitespace
            raise Error, "trailing comma in parameters" if peek(")")

            values << yield
          end
          values
        end

        def parse_identifier
          skip_whitespace
          raise Error, "expected identifier at position #{@position}" unless identifier_start?

          start = @position
          @position += 1 while @position < @source.length && identifier_char?(@source[@position])
          @source[start...@position]
        end

        def parse_quoted_string # rubocop:disable Metrics/MethodLength
          skip_whitespace
          expect("'")
          chars = +""
          while @position < @source.length
            char = @source[@position]
            if char == "\\"
              @position += 1
              raise Error, "unterminated escape in string" if eof?

              chars << @source[@position]
              @position += 1
            elsif char == "'"
              @position += 1
              return chars
            else
              chars << char
              @position += 1
            end
          end
          raise Error, "unterminated string"
        end

        def parse_signed_integer
          skip_whitespace
          start = @position
          @position += 1 if peek("-")
          raise Error, "expected integer at position #{@position}" unless digit?

          @position += 1 while digit?
          Integer(@source[start...@position])
        end

        def expect(token)
          skip_whitespace
          return if consume(token)

          raise Error, "expected #{token.inspect} at position #{@position}"
        end

        def consume(token)
          skip_whitespace
          return false unless @source[@position, token.length] == token

          @position += token.length
          true
        end

        def peek(token)
          skip_whitespace
          @source[@position, token.length] == token
        end

        def skip_whitespace
          @position += 1 while @position < @source.length && @source[@position].match?(/\s/)
        end

        def eof? = @position >= @source.length

        def peek_char = eof? ? nil : @source[@position]

        def digit? = peek_char&.match?(/\d/)

        def identifier_start? = peek_char&.match?(/[A-Za-z_]/)

        def identifier_char?(char) = char.match?(/[A-Za-z0-9_]/)
      end
    end
  end
end
