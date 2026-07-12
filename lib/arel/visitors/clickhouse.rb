# frozen_string_literal: true

module Arel
  module Visitors
    class ClickHouse < ToSql
      private

      # ClickHouse's lightweight-DELETE rewrite resolves WHERE against the mutation's
      # internal projection, where table-qualified column names raise UNKNOWN_IDENTIFIER
      # (code 47) — so compile deletes with bare column names.
      def visit_Arel_Nodes_DeleteStatement(o, collector)
        unqualifying_columns { super }
      end

      def visit_Arel_Attributes_Attribute(o, collector)
        return super unless @unqualify_columns

        collector << quote_column_name(o.name)
      end

      def unqualifying_columns
        @unqualify_columns = true
        yield
      ensure
        @unqualify_columns = false
      end
    end
  end
end
