# frozen_string_literal: true

module Arel
  module Visitors
    class ClickHouse < ToSql
      private

      # ClickHouse's mutation machinery (lightweight DELETE, ALTER UPDATE) resolves WHERE
      # against an internal projection where table-qualified column names raise
      # UNKNOWN_IDENTIFIER (code 47), and it requires an explicit WHERE clause — so
      # mutation statements compile with bare column names and `WHERE 1` when unscoped.
      def visit_Arel_Nodes_DeleteStatement(o, collector)
        o.wheres = [Arel::Nodes::SqlLiteral.new("1")] if o.wheres.empty?
        unqualifying_columns { super }
      end

      # No UPDATE statement in ClickHouse 25.8 without opt-in table settings; the
      # portable write path is the ALTER TABLE ... UPDATE mutation.
      def visit_Arel_Nodes_UpdateStatement(o, collector)
        o = prepare_update_statement(o)

        unqualifying_columns do
          collector << "ALTER TABLE "
          collector = visit o.relation, collector
          collector << " UPDATE "
          collector = inject_join o.values, collector, ", "
          collect_update_wheres(o, collector)
        end
      end

      def collect_update_wheres(o, collector)
        if o.wheres.empty?
          collector << " WHERE 1"
        else
          collector << " WHERE "
          inject_join o.wheres, collector, " AND "
        end
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
