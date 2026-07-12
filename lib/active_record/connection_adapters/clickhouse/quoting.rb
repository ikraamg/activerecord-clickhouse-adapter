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
