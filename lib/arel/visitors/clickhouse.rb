# frozen_string_literal: true

module Arel
  module Visitors
    # Rendering for the adapter's own dialect nodes (WITH FILL, ROLLUP, ARRAY JOIN and
    # the LIMIT BY/SETTINGS suffix) — split from the statement-shape overrides below.
    module ClickHouseDialectRendering
      private

      # LIMIT BY renders before LIMIT (probed: the reverse is a syntax error) and
      # SETTINGS renders last; both ride in the unused lock slot.
      def visit_Arel_Nodes_SelectOptions(o, collector)
        suffix = o.lock if o.lock.is_a?(ActiveRecord::ConnectionAdapters::ClickHouse::Nodes::DialectSuffix)
        return super unless suffix

        collector << " LIMIT #{limit_by_clause(suffix.limit_by)}" if suffix.limit_by
        collector = maybe_visit o.limit, collector
        collector = maybe_visit o.offset, collector
        collector << " SETTINGS #{settings_clause(suffix.settings)}" if suffix.settings.present?
        collector
      end

      def limit_by_clause(limit_by)
        count, columns = limit_by
        "#{count} BY #{columns.map { |column| quote_column_name(column) }.join(", ")}"
      end

      def settings_clause(settings)
        settings.map do |name, value|
          unless /\A[a-zA-Z_][a-zA-Z0-9_]*\z/.match?(name.to_s)
            raise ArgumentError, "invalid ClickHouse setting name: #{name.inspect}"
          end

          "#{name} = #{quote(value)}"
        end.join(", ")
      end

      def visit_ActiveRecord_ConnectionAdapters_ClickHouse_Nodes_OrderWithFill(o, collector)
        collector = visit o.expr, collector
        collector << " WITH FILL"
        collector << " STEP #{o.step}" if o.step
        collector
      end

      # Arel ships RollUp for grouping sets but only the PostgreSQL visitor renders it;
      # ClickHouse shares the GROUP BY ROLLUP(a, b) spelling.
      def visit_Arel_Nodes_RollUp(o, collector)
        collector << "ROLLUP("
        collector = inject_join o.expr, collector, ", "
        collector << ")"
      end

      def visit_ActiveRecord_ConnectionAdapters_ClickHouse_Nodes_ArrayJoin(o, collector)
        collector << "LEFT " if o.left
        collector << "ARRAY JOIN "
        collector = inject_join o.columns, collector, ", "
        collector << " AS #{quote_column_name(o.alias_name)}" if o.alias_name
        collector
      end
    end

    class ClickHouse < ToSql
      include ClickHouseDialectRendering

      private

      # Arel's matches/does_not_match default to case-insensitive; ClickHouse LIKE is
      # case-sensitive but ships native ILIKE (probed live), so this renders exactly
      # like the postgresql visitor. ClickHouse has no ESCAPE clause — backslash is
      # the fixed escape character — so a custom escape refuses loudly.
      def visit_Arel_Nodes_Matches(o, collector)
        raise NotImplementedError, "ClickHouse LIKE has no ESCAPE clause" if o.escape

        infix_value o, collector, o.case_sensitive ? " LIKE " : " ILIKE "
      end

      def visit_Arel_Nodes_DoesNotMatch(o, collector)
        raise NotImplementedError, "ClickHouse LIKE has no ESCAPE clause" if o.escape

        infix_value o, collector, o.case_sensitive ? " NOT LIKE " : " NOT ILIKE "
      end

      # No row locks in ClickHouse (reads are isolated snapshots of parts); FOR UPDATE
      # drops silently so shared Model.lock / with_lock code keeps working — the same
      # contract as the sqlite3 adapter's visitor.
      def visit_Arel_Nodes_Lock(_o, collector)
        collector
      end

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
          collector = collect_update_wheres(o, collector)
          maybe_visit o.comment, collector
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

      def visit_ActiveRecord_ConnectionAdapters_ClickHouse_Nodes_TableWithModifiers(o, collector)
        collector = visit o.expr, collector
        collector << " FINAL" if o.final
        collector << " SAMPLE #{o.sample}" if o.sample
        collector
      end

      def visit_ActiveRecord_ConnectionAdapters_ClickHouse_Nodes_Prewhere(o, collector)
        visit o.expr, collector
      end

      # Prewhere nodes ride through SelectCore#wheres; grammar order is
      # FROM ... [FINAL] [SAMPLE] PREWHERE ... WHERE ...
      def visit_Arel_Nodes_SelectCore(o, collector)
        prewheres, plain_wheres = o.wheres.partition do |node|
          node.is_a?(ActiveRecord::ConnectionAdapters::ClickHouse::Nodes::Prewhere)
        end
        return super if prewheres.empty?

        o = o.dup
        o.wheres = plain_wheres

        with_prewhere_hook(prewheres) { super(o, collector) }
      end

      # SelectCore has no PREWHERE slot, so rendering is spliced in right after the
      # FROM source via visit_Arel_Nodes_JoinSource.
      def visit_Arel_Nodes_JoinSource(o, collector)
        collected = super
        if @pending_prewheres
          collected << " PREWHERE "
          collected = inject_join @pending_prewheres, collected, " AND "
          @pending_prewheres = nil
        end
        collected
      end

      def with_prewhere_hook(prewheres)
        @pending_prewheres = prewheres
        yield
      ensure
        @pending_prewheres = nil
      end

      def visit_Arel_Attributes_Attribute(o, collector)
        return super unless @unqualify_columns

        collector << quote_column_name(o.name)
      end

      # Only the mutation's own WHERE needs bare names; a nested SELECT (the
      # WHERE key IN (subquery) rewrite for ordered/limited/joined mutations) is a
      # regular query where stripping qualifiers makes JOIN columns ambiguous
      # (AMBIGUOUS_COLUMN_NAME, code 352).
      def visit_Arel_Nodes_SelectStatement(o, collector)
        return super unless @unqualify_columns

        @unqualify_columns = false
        begin
          super
        ensure
          @unqualify_columns = true
        end
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
