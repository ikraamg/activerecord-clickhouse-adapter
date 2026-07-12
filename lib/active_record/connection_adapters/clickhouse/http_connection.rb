# frozen_string_literal: true

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
          attr_reader :columns, :types, :rows, :summary, :query_id

          def initialize(columns: [], types: [], rows: [], summary: {}, query_id: nil)
            @columns = columns
            @types = types
            @rows = rows
            @summary = summary
            @query_id = query_id
          end

          def written_rows = Integer(summary.fetch("written_rows", 0))

          # Server-side execution stats, for the sql.active_record notification payload.
          def stats
            {
              query_id: query_id,
              read_rows: Integer(summary.fetch("read_rows", 0)),
              read_bytes: Integer(summary.fetch("read_bytes", 0)),
              written_rows: written_rows,
              elapsed_ns: Integer(summary.fetch("elapsed_ns", 0))
            }
          end
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
            wait_end_of_query: 1,
            # Defaults corrupt silently: Decimals float-parse lossily, NaN/Inf become null.
            output_format_json_quote_decimals: 1,
            output_format_json_quote_denormals: 1,
            # 1/2 make ALTER UPDATE/DELETE mutations block until applied (spec determinism).
            mutations_sync: @config[:mutations_sync],
            # Server gzips responses ~3.6x smaller; Net::HTTP decompresses transparently
            # (it sends Accept-Encoding: gzip by default). Probed 2026-07-12, PLAN.md §2.
            enable_http_compression: @config.fetch(:compression, true) ? 1 : 0
          }.merge(params.transform_keys { |key| "param_#{key}" }).compact
        end

        def raise_execution_error(response)
          code = response["x-clickhouse-exception-code"]&.to_i
          raise ExecutionError.new(response.body.to_s.strip, code: code)
        end

        def parse(response)
          names, types, *rows = response.body.to_s.each_line.map { |line| JSON.parse(line) }

          RawResult.new(
            columns: names || [],
            types: types || [],
            rows: rows,
            summary: JSON.parse(response["x-clickhouse-summary"] || "{}"),
            query_id: response["x-clickhouse-query-id"]
          )
        end
      end
    end
  end
end
