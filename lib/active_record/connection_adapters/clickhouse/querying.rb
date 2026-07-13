# frozen_string_literal: true

module ActiveRecord
  module ConnectionAdapters
    module ClickHouse
      # Custom Arel nodes carrying ClickHouse dialect state through the AST; only
      # Arel::Visitors::ClickHouse knows how to render them.
      module Nodes
        # Wraps the FROM table to append FINAL and/or SAMPLE (table modifiers).
        class TableWithModifiers < ::Arel::Nodes::Unary
          attr_accessor :final, :sample
        end

        # A condition rendered as PREWHERE, smuggled through SelectCore#wheres.
        class Prewhere < ::Arel::Nodes::Unary
        end

        # Rides in SelectStatement#lock (ClickHouse has no row locks): LIMIT BY
        # renders before LIMIT, SETTINGS renders last.
        class DialectSuffix < ::Arel::Nodes::Node
          attr_reader :limit_by, :settings

          def initialize(limit_by: nil, settings: nil)
            super()
            @limit_by = limit_by
            @settings = settings
          end
        end

        # Wraps an ORDER BY expression to append WITH FILL [STEP n] (gap filling).
        class OrderWithFill < ::Arel::Nodes::Unary
          attr_accessor :step
        end

        # ARRAY JOIN unnests array columns into rows; rides the join list so it renders
        # after FROM and any regular JOINs, before WHERE.
        class ArrayJoin < ::Arel::Nodes::Node
          attr_reader :columns, :left, :alias_name

          def initialize(columns, left:, alias_name:)
            super()
            @columns = columns
            @left = left
            @alias_name = alias_name
          end
        end
      end

      # Relation methods for the ClickHouse query surface. Injected via
      # `extending` (public Relation API) by ClickHouse::Querying — no reopens.
      module RelationMethods
        def final = spawn.final!

        def final!
          assign_clickhouse_dialect(final: true)
        end

        def sample(fraction) = spawn.sample!(fraction)

        def sample!(fraction)
          assign_clickhouse_dialect(sample: Float(fraction))
        end

        def prewhere(condition) = spawn.prewhere!(condition)

        def prewhere!(condition)
          sanitized = klass.send(:sanitize_sql_for_conditions, condition)
          assign_clickhouse_dialect(prewhere: [*clickhouse_dialect[:prewhere], sanitized])
        end

        def settings(values) = spawn.settings!(values)

        def settings!(values)
          assign_clickhouse_dialect(settings: (clickhouse_dialect[:settings] || {}).merge(values))
        end

        def limit_by(count, *columns) = spawn.limit_by!(count, *columns)

        def limit_by!(count, *columns)
          assign_clickhouse_dialect(limit_by: [Integer(count), columns.flatten])
        end

        # toStartOfInterval buckets any period the server knows; grouping and ordering
        # by the same expression makes `.count` come back as a chronological series.
        GROUP_BY_PERIODS = %w[minute hour day week month quarter year].freeze

        def group_by_period(period, column) = spawn.group_by_period!(period, column)

        def group_by_period!(period, column)
          unless GROUP_BY_PERIODS.include?(period.to_s)
            raise ArgumentError, "unknown period #{period.inspect}; use one of #{GROUP_BY_PERIODS.join(", ")}"
          end

          bucket = ::Arel::Nodes::NamedFunction.new(
            "toStartOfInterval", [klass.arel_table[column], ::Arel.sql("INTERVAL 1 #{period}")]
          )
          group!(bucket).order!(bucket)
        end

        def fill(step: nil) = spawn.fill!(step: step)

        def fill!(step: nil)
          assign_clickhouse_dialect(fill: { step: fill_step_sql(step) })
        end

        # Unnests array columns into one row per element; as: names the element so the
        # original array column stays addressable. left: true keeps empty-array rows.
        def array_join(*columns, left: false, as: nil) = spawn.array_join!(*columns, left: left, as: as)

        def array_join!(*columns, left: false, as: nil)
          raise ArgumentError, "as: names a single element, so array_join takes one column with it" if
            as && columns.many?

          assign_clickhouse_dialect(array_join: { columns: columns.flatten, left: left, as: as })
        end

        # ClickHouse renders WITH TOTALS out-of-band, which the row-stream wire format
        # drops (probed 2026-07-13) — ROLLUP delivers totals as ordinary rows instead,
        # keyed nil thanks to group_by_use_nulls.
        def rollup = spawn.rollup!

        def rollup!
          settings!(group_by_use_nulls: 1)
          assign_clickhouse_dialect(rollup: true)
        end

        def clickhouse_dialect
          @clickhouse_dialect ||= {}
        end

        private

        def assign_clickhouse_dialect(changes)
          @clickhouse_dialect = clickhouse_dialect.merge(changes)
          self
        end

        def fill_step_sql(step)
          case step
          when nil then nil
          when ActiveSupport::Duration then "INTERVAL #{Integer(step.to_i)} SECOND"
          else Integer(step).to_s
          end
        end

        def build_arel(...)
          manager = super
          apply_clickhouse_dialect(manager.ast) unless clickhouse_dialect.empty?
          manager
        end
      end

      # Compiles the dialect state RelationMethods accumulated into the Arel AST right
      # before SQL generation; only RelationMethods#build_arel calls in here.
      module RelationDialectCompilation
        private

        def apply_clickhouse_dialect(ast)
          dialect = clickhouse_dialect
          core = ast.cores.last
          apply_table_modifiers(core, dialect)
          apply_array_join(core, dialect)
          apply_prewheres(core, dialect)
          apply_rollup(core, dialect)
          apply_fill(ast, dialect)
          return unless dialect[:limit_by] || dialect[:settings]

          ast.lock = Nodes::DialectSuffix.new(limit_by: dialect[:limit_by], settings: dialect[:settings])
        end

        def apply_array_join(core, dialect)
          spec = dialect[:array_join] or return

          columns = spec[:columns].map { |column| klass.arel_table[column] }
          core.source.right << Nodes::ArrayJoin.new(columns, left: spec[:left], alias_name: spec[:as])
        end

        def apply_rollup(core, dialect)
          return unless dialect[:rollup]
          raise ArgumentError, "rollup requires a grouped relation" if core.groups.empty?

          core.groups = [::Arel::Nodes::Group.new(::Arel::Nodes::RollUp.new(core.groups.map(&:expr)))]
        end

        def apply_fill(ast, dialect)
          fill = dialect[:fill] or return
          raise ArgumentError, "fill requires an ordered relation (WITH FILL rides on ORDER BY)" if ast.orders.empty?

          filled = Nodes::OrderWithFill.new(ast.orders.pop)
          filled.step = fill[:step]
          ast.orders.push(filled)
        end

        def apply_prewheres(core, dialect)
          Array(dialect[:prewhere]).each do |condition|
            core.wheres.unshift(Nodes::Prewhere.new(::Arel.sql(condition)))
          end
        end

        def apply_table_modifiers(core, dialect)
          return unless dialect[:final] || dialect[:sample]

          modified = Nodes::TableWithModifiers.new(core.source.left)
          modified.final = dialect[:final]
          modified.sample = dialect[:sample]
          core.source.left = modified
        end
      end

      # Writes can't carry an in-SQL SETTINGS clause the way SELECTs do (ALTER and
      # INSERT grammars each differ), so a relation's settings travel as per-request
      # HTTP query parameters instead.
      module RelationWrites
        def update_all(...) = with_write_settings { super }

        def delete_all(...) = with_write_settings { super }

        def insert_all(...) = with_write_settings { super }

        def insert_all!(...) = with_write_settings { super }

        private

        def with_write_settings(&block)
          settings = clickhouse_dialect[:settings]
          return yield if settings.blank?

          klass.with_connection { |connection| connection.with_request_settings(settings, &block) }
        end
      end

      # Terminal calculations over ClickHouse's aggregate-function library; separate
      # from RelationMethods because these execute immediately rather than build state.
      # All accept merge: true (-Merge, finishing AggregateFunction state columns) and
      # if: condition (-If, per-row conditional aggregation in a single scan); `if` is
      # a Ruby keyword, so it travels in **options.
      module RelationCalculations
        def uniq_count(column, exact: false, merge: false, **options)
          aggregate(exact ? "uniqExact" : "uniq", [klass.arel_table[column]],
                    merge: merge, condition: options[:if])
        end

        # Parametric aggregates render as name(param)(args); Float/Integer coercion is
        # the injection guard for the parameter.
        def quantile(fraction, column, merge: false, **options)
          aggregate("quantile", [klass.arel_table[column]],
                    parameter: Float(fraction), merge: merge, condition: options[:if])
        end

        def top_k(count, column, merge: false, **options)
          aggregate("topK", [klass.arel_table[column]],
                    parameter: Integer(count), merge: merge, condition: options[:if])
        end

        def arg_max(column, criterion, **options)
          aggregate("argMax", [klass.arel_table[column], klass.arel_table[criterion]], condition: options[:if])
        end

        def arg_min(column, criterion, **options)
          aggregate("argMin", [klass.arel_table[column], klass.arel_table[criterion]], condition: options[:if])
        end

        # Table-level row estimate from metadata — O(1), ignores relation scopes.
        def estimated_count
          klass.with_connection do |connection|
            connection.select_value(<<~SQL.squish, "#{klass.name} Estimated Count").to_i
              SELECT total_rows FROM system.tables
              WHERE database = currentDatabase() AND name = #{connection.quote(klass.table_name)}
            SQL
          end
        end

        private

        def aggregate(name, columns, parameter: nil, merge: false, condition: nil)
          raise ArgumentError, "merge: and if: cannot combine (ClickHouse has no -MergeIf)" if merge && condition

          function = +name
          function << "Merge" if merge
          function << "If" if condition
          function << "(#{parameter})" unless parameter.nil?
          columns << condition_node(condition) if condition
          pick_aggregate(function, columns)
        end

        # Hashes go through the relation's own predicate builder (ranges, arrays and
        # casting come free); strings/arrays through sanitize_sql like prewhere.
        def condition_node(condition)
          return klass.unscoped.where(condition).where_clause.ast if condition.is_a?(Hash)

          ::Arel.sql(klass.send(:sanitize_sql_for_conditions, condition))
        end

        # Ungrouped: one value. Grouped: a hash keyed like Rails' grouped calculations
        # (scalar for one group column, array for several).
        def pick_aggregate(function, columns)
          node = ::Arel::Nodes::NamedFunction.new(function, columns)
          return unscope(:order, :select).pick(node) if group_values.empty?

          pluck(*group_values, node)
            .to_h { |row| [group_values.many? ? row[0..-2] : row.first, row.last] }
        end
      end

      # Opt-in model concern: `include ActiveRecord::ConnectionAdapters::ClickHouse::Querying`
      # gives every relation of the model the ClickHouse dialect surface
      # (.final/.sample/.prewhere/.settings/.limit_by/.group_by_period/.fill/.rollup)
      # and the OLAP calculations (.uniq_count/.quantile/.top_k/.arg_max/.arg_min).
      module Querying
        extend ActiveSupport::Concern

        included do
          default_scope do
            extending(RelationMethods, RelationDialectCompilation, RelationWrites, RelationCalculations)
          end
        end

        class_methods do
          delegate :final, :sample, :prewhere, :settings, :limit_by, :array_join,
                   :group_by_period, :fill, :rollup, :uniq_count, :quantile,
                   :top_k, :arg_max, :arg_min, :estimated_count, to: :all

          # insert_all's streaming sibling: the batch goes over the wire as one
          # chunked INSERT instead of being rendered into a SQL string first.
          def insert_stream(rows, columns: nil)
            with_connection { |connection| connection.insert_stream(table_name, rows, columns: columns) }
          end
        end
      end
    end
  end
end
