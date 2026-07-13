# frozen_string_literal: true

# -If combinators aggregate over a per-row condition inside one scan — several
# conditional metrics in a single pass instead of one WHERE'd query each.
RSpec.describe "ClickHouse conditional aggregates" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "agg_if_probe"

      def self.name = "AggIfProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("agg_if_probe", if_exists: true)
    conn.create_table("agg_if_probe", order: "device_id") do |t|
      t.integer :device_id, limit: 8
      t.string :event_type
      t.integer :duration_ms, limit: 8
    end
    conn.execute(<<~SQL.squish)
      INSERT INTO agg_if_probe
      SELECT number % 4, ['render', 'sync'][(number % 2) + 1], number * 10 FROM numbers(20)
    SQL
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("agg_if_probe", if_exists: true)
  end

  # Renders land on even numbers only, so devices 0 and 2 (n % 4 of even n).
  it "counts distinct values matching a condition" do
    expect(model.uniq_count(:device_id, if: { event_type: "render" })).to eq(2)
  end

  it "sanitizes array conditions" do
    expect(model.uniq_count(:device_id, if: ["duration_ms < ?", 20])).to eq(2)
  end

  it "combines a condition with a parametric aggregate" do
    expect(model.quantile(1.0, :duration_ms, if: { event_type: "sync" })).to eq(190)
  end

  it "conditions arg_max on the criterion" do
    expect(model.arg_max(:event_type, :duration_ms, if: ["duration_ms <= ?", 180])).to eq("render")
  end

  it "composes if: with merge: on state columns by refusing loudly" do
    expect { model.uniq_count(:device_id, merge: true, if: { event_type: "x" }) }
      .to raise_error(ArgumentError, /merge/)
  end
end
