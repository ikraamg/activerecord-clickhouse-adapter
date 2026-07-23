# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      class UnknownTable < ActiveRecord::StatementInvalid; end
      class UnknownDatabase < ActiveRecord::StatementInvalid; end
      class MemoryLimitExceeded < ActiveRecord::StatementInvalid; end
      class QueryTimeout < ActiveRecord::StatementInvalid; end
      class AuthenticationError < ActiveRecord::StatementInvalid; end
      class AccessDenied < ActiveRecord::StatementInvalid; end

      module ErrorTranslation
        EXCEPTION_CLASS_BY_CODE = {
          60 => UnknownTable,
          81 => UnknownDatabase,
          241 => MemoryLimitExceeded,
          159 => QueryTimeout,
          160 => QueryTimeout,
          497 => AccessDenied,
          516 => AuthenticationError
        }.freeze

        # Code 53 is TYPE_MISMATCH at large; only its NULL-insert shape (surfaced by
        # input_format_null_as_default = 0) is a Rails not-null violation.
        NULL_INSERT_MESSAGE = /Cannot insert NULL value into a column of type/

        # READONLY: the server refusing a write for a readonly user or a
        # read_only: true connection — same refusal Rails models client-side
        # with while_preventing_writes, so it raises Rails' class for it.
        READONLY_CODE = 164

        private

        def translate_exception(exception, message:, sql:, binds:)
          return ActiveRecord::ReadOnlyError.new(message) if readonly_refusal?(exception)

          server_error = server_exception_class(exception)
          return server_error.new(message, sql: sql, binds: binds) if server_error

          case exception
          when Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout
            ActiveRecord::ConnectionNotEstablished.new(exception)
          else
            super
          end
        end

        def readonly_refusal?(exception)
          exception.is_a?(HTTPConnection::ExecutionError) && exception.code == READONLY_CODE
        end

        def server_exception_class(exception)
          return nil unless exception.is_a?(HTTPConnection::ExecutionError)

          if exception.code == 53 && exception.message.match?(NULL_INSERT_MESSAGE)
            ActiveRecord::NotNullViolation
          else
            EXCEPTION_CLASS_BY_CODE[exception.code]
          end
        end
      end
    end
  end
end
