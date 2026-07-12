# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      class UnknownTable < ActiveRecord::StatementInvalid; end
      class UnknownDatabase < ActiveRecord::StatementInvalid; end
      class MemoryLimitExceeded < ActiveRecord::StatementInvalid; end
      class QueryTimeout < ActiveRecord::StatementInvalid; end
      class AuthenticationError < ActiveRecord::StatementInvalid; end

      module ErrorTranslation
        EXCEPTION_CLASS_BY_CODE = {
          60 => UnknownTable,
          81 => UnknownDatabase,
          241 => MemoryLimitExceeded,
          159 => QueryTimeout,
          160 => QueryTimeout,
          516 => AuthenticationError
        }.freeze

        private

        def translate_exception(exception, message:, sql:, binds:)
          if exception.is_a?(HTTPConnection::ExecutionError)
            klass = EXCEPTION_CLASS_BY_CODE[exception.code]
            return klass.new(message, sql: sql, binds: binds) if klass
          end

          case exception
          when Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout
            ActiveRecord::ConnectionNotEstablished.new(exception)
          else
            super
          end
        end
      end
    end
  end
end
