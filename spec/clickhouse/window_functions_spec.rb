# frozen_string_literal: true

# Window-function relation sugar: one projected OVER (PARTITION BY ... ORDER BY ...)
# expression per call, compiled through Arel's own window nodes. Probed live
# 2026-07-14: ClickHouse 25.8 supports lag/lead directly (no lagInFrame dance) and
# ROWS/RANGE/GROUPS frames.
RSpec.describe "ClickHouse window-function relation sugar" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "window_probe"

      def self.name = "WindowProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("window_probe", if_exists: true)
    conn.create_table("window_probe", order: "(device_id, observed_at)") do |t|
      t.integer :device_id, limit: 8
      t.integer :battery, limit: 8
      t.datetime :observed_at, precision: 6
    end
    # Two devices, three readings each, batteries draining at different rates.
    conn.execute(<<~SQL.squish)
      INSERT INTO window_probe
      SELECT number % 2, 100 - number * 10,
             toDateTime64('2026-07-14 00:00:00', 6) + INTERVAL number MINUTE
      FROM numbers(6)
    SQL
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("window_probe", if_exists: true)
  end

  describe ".window" do
    it "numbers rows per partition" do
      rows = model.window(:row_number, as: :position, partition_by: :device_id, order_by: :observed_at)
                  .order(:device_id, :observed_at).map { |row| row[:position] }
      expect(rows).to eq([1, 2, 3, 1, 2, 3])
    end

    it "keeps the model's own columns selected alongside the window value" do
      row = model.window(:row_number, as: :position, order_by: :observed_at).order(:observed_at).first
      expect(row.battery).to eq(100)
    end

    it "computes running totals with an ordered aggregate" do
      totals = model.window(:sum, :battery, as: :drained, partition_by: :device_id, order_by: :observed_at)
                    .where(device_id: 0).order(:observed_at).map { |row| row[:drained] }
      expect(totals).to eq([100, 180, 240])
    end

    it "reaches back a row with lag" do
      previous = model.window(:lag, :battery, as: :previous_battery, partition_by: :device_id, order_by: :observed_at)
                      .where(device_id: 1).order(:observed_at).map { |row| row[:previous_battery] }
      expect(previous).to eq([0, 90, 70])
    end

    it "honors an explicit frame" do
      pairs = model.window(:sum, :battery, as: :pair_total, partition_by: :device_id, order_by: :observed_at,
                                           frame: "ROWS BETWEEN 1 PRECEDING AND CURRENT ROW")
                   .where(device_id: 0).order(:observed_at).map { |row| row[:pair_total] }
      expect(pairs).to eq([100, 180, 140])
    end

    it "composes with select" do
      row = model.select(:device_id).window(:row_number, as: :position, order_by: :observed_at)
                 .order(:observed_at).first
      expect(row.attributes.keys).to contain_exactly("device_id", "position")
    end

    it "orders partitions descending through a hash" do
      first = model.window(:row_number, as: :position, order_by: { battery: :desc }).order(:observed_at).first
      expect(first[:position]).to eq(1)
    end

    it "rejects function names that are not identifiers" do
      expect { model.window("sum(1); DROP TABLE x", as: :bad) }.to raise_error(ArgumentError, /function/)
    end

    it "rejects aliases that are not identifiers" do
      expect { model.window(:row_number, as: "x; DROP TABLE y") }.to raise_error(ArgumentError, /alias/)
    end

    it "rejects frames outside the frame grammar" do
      expect { model.window(:sum, :battery, as: :bad, frame: "ROWS'; DROP TABLE x") }
        .to raise_error(ArgumentError, /frame/)
    end
  end
end
