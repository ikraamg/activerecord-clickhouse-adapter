# frozen_string_literal: true

require "bigdecimal"
require "json"
require "net/http"
require "uri"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Raw connection to a ClickHouse server over its HTTP interface: one persistent
      # keep-alive Net::HTTP socket per adapter instance (the adapter lock serializes use).
      # Results arrive as JSONCompactEachRowWithNamesAndTypes — names line, types line,
      # then one JSON array per row — so every value comes back with its server type.
      class HTTPConnection
        SELECT_FORMAT = "JSONCompactEachRowWithNamesAndTypes"

        class ExecutionError < StandardError
          attr_reader :code

          def initialize(message, code: nil)
            super(message)
            @code = code
          end
        end

        class RawResult
          attr_reader :columns, :types, :rows, :summary

          def initialize(columns: [], types: [], rows: [], summary: {})
            @columns = columns
            @types = types
            @rows = rows
            @summary = summary
          end

          def written_rows = Integer(summary.fetch("written_rows", 0))
        end

        def initialize(config)
          @config = config
          @http = build_http
        end

        def execute(sql, params: {})
          response = @http.request(build_request(sql, params))
          raise_execution_error(response) unless response.is_a?(Net::HTTPSuccess)

          parse(response)
        end

        def ping
          execute("SELECT 1")
          true
        rescue StandardError
          false
        end

        def close
          @http.finish if @http.started?
        rescue IOError
          nil
        end

        private

        def build_http
          http = Net::HTTP.new(@config[:host], @config[:port])
          http.use_ssl = @config[:ssl] if @config.key?(:ssl)
          http.open_timeout = @config[:connect_timeout] if @config[:connect_timeout]
          http.read_timeout = @config[:read_timeout] if @config[:read_timeout]
          http.write_timeout = @config[:write_timeout] if @config[:write_timeout]
          http
        end

        def build_request(sql, params)
          request = Net::HTTP::Post.new("/?#{URI.encode_www_form(query_params(params))}")
          request["X-ClickHouse-User"] = @config[:username] if @config[:username]
          request["X-ClickHouse-Key"] = @config[:password] if @config[:password]
          request.body = sql
          request
        end

        def query_params(params)
          {
            database: @config[:database],
            default_format: SELECT_FORMAT,
            wait_end_of_query: 1
          }.merge(params.transform_keys { |key| "param_#{key}" }).compact
        end

        def raise_execution_error(response)
          code = response["x-clickhouse-exception-code"]&.to_i
          raise ExecutionError.new(response.body.to_s.strip, code: code)
        end

        def parse(response)
          # decimal_class keeps Decimal(P,S) exact; Float casters convert BigDecimal → Float.
          names, types, *rows = response.body.to_s.each_line.map do |line|
            JSON.parse(line, decimal_class: BigDecimal)
          end

          RawResult.new(
            columns: names || [],
            types: types || [],
            rows: rows,
            summary: JSON.parse(response["x-clickhouse-summary"] || "{}")
          )
        end
      end
    end
  end
end
