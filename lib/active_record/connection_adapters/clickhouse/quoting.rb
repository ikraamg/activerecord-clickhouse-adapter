# frozen_string_literal: true

require "ipaddr"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      module Quoting
        extend ActiveSupport::Concern

        class_methods do
          def quote_column_name(name)
            "`#{name.to_s.gsub("`", "``")}`"
          end

          def quote_table_name(name)
            name.to_s.split(".").map { |part| quote_column_name(part) }.join(".")
          end
        end

        def quote_string(string)
          # Block form — \' in a gsub replacement string means "post-match", not backslash-quote.
          string.gsub(/[\\']/) { |char| char == "\\" ? "\\\\" : "\\'" }
        end

        # DateTime64 stores an epoch and the server parses naive strings in its own
        # timezone (UTC here); params reject offsets outright (code 457, PLAN.md §2).
        # UTC is therefore the only faithful wire encoding, whatever default_timezone says.
        def quoted_date(value)
          value = value.getutc if value.acts_like?(:time) && !value.utc?
          result = value.to_fs(:db)
          value.respond_to?(:usec) && value.usec.positive? ? "#{result}.#{format("%06d", value.usec)}" : result
        end

        def quoted_true = "true"
        def quoted_false = "false"
        def unquoted_true = true
        def unquoted_false = false

        def quote(value)
          case value
          when Array then "[#{value.map { |item| quote(item) }.join(", ")}]"
          when Hash then "{#{value.map { |key, item| "#{quote(key)}: #{quote(item)}" }.join(", ")}}"
          when IPAddr then "'#{quote_string(value.to_s)}'"
          else super
          end
        end
      end
    end
  end
end
