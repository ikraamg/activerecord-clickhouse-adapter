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

        def clickhouse_dialect
          @clickhouse_dialect ||= {}
        end

        private

        def assign_clickhouse_dialect(changes)
          @clickhouse_dialect = clickhouse_dialect.merge(changes)
          self
        end

        def build_arel(...)
          manager = super
          apply_clickhouse_dialect(manager.ast) unless clickhouse_dialect.empty?
          manager
        end

        def apply_clickhouse_dialect(ast)
          dialect = clickhouse_dialect
          core = ast.cores.last
          apply_table_modifiers(core, dialect)
          apply_prewheres(core, dialect)
          return unless dialect[:limit_by] || dialect[:settings]

          ast.lock = Nodes::DialectSuffix.new(limit_by: dialect[:limit_by], settings: dialect[:settings])
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

      # Opt-in model concern: `include ActiveRecord::ConnectionAdapters::ClickHouse::Querying`
      # gives every relation of the model .final/.sample/.prewhere/.settings/.limit_by.
      module Querying
        extend ActiveSupport::Concern

        included do
          default_scope { extending(RelationMethods) }
        end

        class_methods do
          delegate :final, :sample, :prewhere, :settings, :limit_by, to: :all
        end
      end
    end
  end
end
