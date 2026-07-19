# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

require "active_record/connection_adapters/clickhouse/row_binary"

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Raw connection to a ClickHouse server over its HTTP interface: one persistent
      # keep-alive Net::HTTP socket per adapter instance (the adapter lock serializes use).
      # Results arrive as RowBinaryWithNamesAndTypes by default — names, type strings,
      # then packed binary rows — so every value comes back with its server type; queries
      # whose types have no binary decoder retry transparently on the JSON wire
      # (select_format: :json in the config forces JSON for everything).
      class HTTPConnection
        BINARY_FORMAT = "RowBinaryWithNamesAndTypes"
        JSON_FORMAT = "JSONCompactEachRowWithNamesAndTypes"

        # Failures raised before the request reaches a server: retrying them on
        # another replica can never double a write. Anything mid-flight (read
        # timeout, reset) raises instead — the statement may have executed.
        CONNECT_ERRORS = [Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError, Net::OpenTimeout].freeze

        # Process-wide replica ledger: rotates the starting endpoint across
        # connections and remembers connect failures so fresh connections skip
        # an endpoint that refused within the (per-config) cooldown window.
        @start_counter = 0
        @connect_failure_times = {}
        @ledger_lock = Mutex.new

        class << self
          def claim_start_index(endpoints, cooldown)
            @ledger_lock.synchronize do
              start = @start_counter % endpoints.size
              @start_counter += 1
              healthy_offset = endpoints.size.times.find do |offset|
                !recently_failed?(endpoints[(start + offset) % endpoints.size], cooldown)
              end
              (start + (healthy_offset || 0)) % endpoints.size
            end
          end

          def record_connect_failure(endpoint)
            @ledger_lock.synchronize do
              @connect_failure_times[endpoint] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          private

          def recently_failed?(endpoint, cooldown)
            failed_at = @connect_failure_times[format_endpoint(endpoint)]
            failed_at && Process.clock_gettime(Process::CLOCK_MONOTONIC) - failed_at < cooldown
          end

          def format_endpoint(endpoint) = endpoint.join(":")
        end

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
          @select_format = config[:select_format].to_s == "json" ? JSON_FORMAT : BINARY_FORMAT
          @endpoints = build_endpoints
          @endpoint_index = self.class.claim_start_index(@endpoints, failover_cooldown)
          @http = nil
        end

        def current_endpoint
          @endpoints[@endpoint_index].join(":")
        end

        # Adapts an enumerator of encoded lines to the partial-read IO contract
        # Net::HTTP uses for chunked transfer encoding, so a streamed INSERT never
        # holds more than one chunk of the body in memory.
        class ChunkedBody
          CHUNK_BYTES = 64 * 1024

          def initialize(lines)
            @lines = lines
            @buffer = +""
          end

          def read(length = CHUNK_BYTES, out = +"")
            buffer_lines(length)
            return nil if @buffer.empty?

            out.replace(@buffer.slice!(0, length))
          end

          private

          def buffer_lines(length)
            @buffer << @lines.next << "\n" while @buffer.bytesize < length
          rescue StopIteration
            nil
          end
        end

        def execute(sql, params: {})
          parse(perform(sql, params, @select_format), @select_format)
        rescue RowBinary::Undecodable
          parse(perform(sql, params, JSON_FORMAT), JSON_FORMAT)
        end

        # Streams pre-encoded body lines as one chunked POST; the statement travels
        # in the query string because the request body is the data.
        def execute_stream(sql, lines)
          request = post_request(query_params({}, JSON_FORMAT).merge(query: sql))
          request["Transfer-Encoding"] = "chunked"
          request.body_stream = ChunkedBody.new(lines)
          parse(raise_unless_success(send_request(request)), JSON_FORMAT)
        end

        # Scopes extra server settings to the requests made inside the block — the
        # write-side counterpart of the SETTINGS clause SELECTs carry in-SQL.
        def with_request_settings(settings)
          previous = @request_settings
          @request_settings = (previous || {}).merge(settings)
          yield
        ensure
          @request_settings = previous
        end

        def ping
          execute("SELECT 1")
          true
        rescue StandardError
          false
        end

        def close
          @http.finish if @http&.started?
        rescue IOError
          nil
        end

        private

        def http
          @http ||= build_http
        end

        # Walks the endpoint list on connect-phase failures, at most one attempt
        # per endpoint. A single-host config raises immediately, as before.
        def send_request(request)
          attempts = 0
          begin
            http.request(request)
          rescue *CONNECT_ERRORS
            attempts += 1
            raise if attempts >= @endpoints.size

            rotate_endpoint
            retry
          end
        end

        def rotate_endpoint
          self.class.record_connect_failure(current_endpoint)
          close
          @http = nil
          @endpoint_index = (@endpoint_index + 1) % @endpoints.size
        end

        # hosts: lists interchangeable replicas as "host" or "host:port" strings
        # (the port: key is the default); host:/port: alone stay a single endpoint.
        def build_endpoints
          hosts = Array(@config[:hosts])
          return [[@config[:host], @config[:port]]] if hosts.empty?

          hosts.map do |entry|
            host, port = entry.to_s.split(":", 2)
            [host, port ? Integer(port) : @config[:port] || 8123]
          end
        end

        def failover_cooldown
          @config.fetch(:failover_cooldown, 30)
        end

        def build_http
          host, port = @endpoints[@endpoint_index]
          http = Net::HTTP.new(host, port)
          configure_tls(http)
          http.open_timeout = @config[:connect_timeout] if @config[:connect_timeout]
          http.read_timeout = @config[:read_timeout] if @config[:read_timeout]
          http.write_timeout = @config[:write_timeout] if @config[:write_timeout]
          http
        end

        # Verification stays ON by default; ssl_verify: false is the explicit escape
        # hatch for sinks terminating TLS with a self-signed certificate.
        def configure_tls(http)
          http.use_ssl = @config[:ssl] if @config.key?(:ssl)
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @config[:ssl_verify] == false
        end

        def perform(sql, params, format)
          request = post_request(query_params(params, format))
          request.body = sql
          raise_unless_success(send_request(request))
        end

        def post_request(params)
          request = Net::HTTP::Post.new("/?#{URI.encode_www_form(params)}")
          request["X-ClickHouse-User"] = @config[:username] if @config[:username]
          request["X-ClickHouse-Key"] = @config[:password] if @config[:password]
          request
        end

        def raise_unless_success(response)
          raise_execution_error(response) unless response.is_a?(Net::HTTPSuccess)

          response
        end

        def query_params(params, format)
          session_settings(format).merge(async_insert_params)
                                  .merge(@request_settings || {})
                                  .merge(params.transform_keys { |key| "param_#{key}" }).compact
        end

        # Defaults corrupt silently: JSON Decimals float-parse lossily, NaN/Inf become
        # null; binary JSON columns have no stable layout, so they travel as text.
        OUTPUT_SETTINGS = {
          output_format_json_quote_decimals: 1,
          output_format_json_quote_denormals: 1,
          output_format_binary_write_json_as_string: 1
        }.freeze
        private_constant :OUTPUT_SETTINGS

        def session_settings(format)
          OUTPUT_SETTINGS.merge(
            database: @config[:database],
            default_format: format,
            wait_end_of_query: 1,
            # 1/2 make ALTER UPDATE/DELETE mutations block until applied (spec determinism).
            mutations_sync: @config[:mutations_sync],
            # ClickHouse fills non-matched outer-join columns with type defaults (0, '');
            # every other AR adapter returns SQL NULLs, so default to standard semantics.
            join_use_nulls: @config.fetch(:join_use_nulls, 1),
            # By default the server coerces NULL to the type default on insert into a
            # non-Nullable column — silent data corruption by AR semantics. Off, the
            # insert raises (code 53, probed 2026-07-14) and maps to NotNullViolation.
            input_format_null_as_default: 0,
            # Server gzips responses ~3.6x smaller; Net::HTTP decompresses transparently
            # (it sends Accept-Encoding: gzip by default). Probed 2026-07-12, PLAN.md §2.
            enable_http_compression: @config.fetch(:compression, true) ? 1 : 0,
            # readonly=2 (not 1): strict readonly refuses the settings above with
            # code 164 before any query runs — probed live 2026-07-19.
            readonly: @config[:read_only] ? 2 : nil
          )
        end

        # Server-side batching for high-frequency small INSERTs. wait_for_async_insert
        # defaults to 1 so an acked insert is durable; 0 (fire-and-forget) is an
        # explicit opt-in because it loses acked rows on a server crash.
        def async_insert_params
          return {} unless @config[:async_insert]

          { async_insert: 1, wait_for_async_insert: @config.fetch(:wait_for_async_insert, 1) }
        end

        def raise_execution_error(response)
          code = response["x-clickhouse-exception-code"]&.to_i
          raise ExecutionError.new(response.body.to_s.strip, code: code)
        end

        def parse(response, format)
          names, types, rows = decode_body(response.body.to_s, format)

          RawResult.new(
            columns: names, types: types, rows: rows,
            summary: JSON.parse(response["x-clickhouse-summary"] || "{}"),
            query_id: response["x-clickhouse-query-id"]
          )
        end

        def decode_body(body, format)
          return RowBinary.decode(body) if format == BINARY_FORMAT

          names, types, *rows = body.each_line.map { |line| JSON.parse(line) }
          [names || [], types || [], rows]
        end
      end
    end
  end
end
