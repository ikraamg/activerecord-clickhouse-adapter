# frozen_string_literal: true

# OLAP-native relation surface (approved 2026-07-13): time bucketing, gap filling,
# approximate aggregates, rollup totals, and metadata counts — each an ActiveRecord-shaped
# veneer over one ClickHouse capability.
RSpec.describe "ClickHouse OLAP relation extensions" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "olap_probe"

      def self.name = "OlapProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("olap_probe", if_exists: true)
    conn.create_table("olap_probe", order: "(device_id, created_at)") do |t|
      t.integer :device_id, limit: 8
      t.string :event_type
      t.integer :duration_ms, limit: 8
      t.datetime :created_at, precision: 6
    end
    # 20 rows, 25 minutes apart from midnight: buckets thin out over the morning.
    conn.execute(<<~SQL.squish)
      INSERT INTO olap_probe
      SELECT number % 3, ['render', 'sync'][(number % 2) + 1], number * 10,
             toDateTime64('2026-07-13 00:00:00', 6) + INTERVAL (number * 25) MINUTE
      FROM numbers(20)
    SQL
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("olap_probe", if_exists: true)
  end

  describe ".group_by_period" do
    it "buckets counts by hour" do
      counts = model.group_by_period(:hour, :created_at).count
      expect(counts[Time.utc(2026, 7, 13, 0)]).to eq(3)
    end

    it "orders buckets chronologically" do
      buckets = model.group_by_period(:hour, :created_at).count.keys
      expect(buckets).to eq(buckets.sort)
    end

    it "buckets by day" do
      expect(model.group_by_period(:day, :created_at).count.keys).to eq([Date.new(2026, 7, 13)])
    end

    it "composes with where scopes" do
      counts = model.where(device_id: 1).group_by_period(:hour, :created_at).count
      expect(counts.values.sum).to eq(7)
    end

    it "rejects unknown periods" do
      expect { model.group_by_period(:fortnight, :created_at) }.to raise_error(ArgumentError, /period/)
    end
  end

  describe ".fill" do
    it "fills gaps in an ordered time series with zero rows" do
      sparse = model.where(device_id: 1)
      buckets = sparse.group_by_period(:hour, :created_at).fill(step: 30.minutes).count
      expect(buckets.length).to be > sparse.group_by_period(:hour, :created_at).count.length
    end

    it "fills numeric sequences with an integer step" do
      values = model.where(device_id: [0, 2]).group(:device_id).order(:device_id).fill(step: 1).count
      expect(values.keys).to eq([0, 1, 2])
    end

    it "requires an ordered relation" do
      expect { model.all.fill(step: 1).to_sql }.to raise_error(ArgumentError, /order/i)
    end
  end

  describe ".rollup" do
    # WITH TOTALS emits its row out-of-band and our wire format drops it (probed
    # 2026-07-13, PLAN.md §2); ROLLUP totals arrive as ordinary rows keyed nil.
    it "adds a grand-total row keyed nil" do
      counts = model.group(:event_type).rollup.count
      expect(counts[nil]).to eq(20)
    end

    it "keeps the per-group rows" do
      counts = model.group(:event_type).rollup.count
      expect(counts["render"]).to eq(10)
    end

    it "adds subtotal rows per outer group across two dimensions" do
      counts = model.group(:device_id, :event_type).rollup.count
      expect(counts[[0, nil]]).to eq(7)
    end
  end

  describe "approximate aggregates" do
    it "estimates distinct counts with uniq" do
      expect(model.uniq_count(:device_id)).to eq(3)
    end

    it "counts exactly with uniq_count(exact: true)" do
      expect(model.uniq_count(:device_id, exact: true)).to eq(3)
    end

    it "computes quantiles server-side" do
      expect(model.quantile(0.5, :duration_ms)).to be_within(10).of(95)
    end

    it "composes quantile with where scopes" do
      expect(model.where(device_id: 0).quantile(1.0, :duration_ms)).to eq(180)
    end

    it "returns the most frequent values with top_k" do
      expect(model.top_k(2, :event_type)).to contain_exactly("render", "sync")
    end

    it "answers arg_max as the value at the row maximizing the criterion" do
      expect(model.arg_max(:event_type, :duration_ms)).to eq("sync")
    end

    it "answers arg_min as the value at the row minimizing the criterion" do
      expect(model.arg_min(:event_type, :duration_ms)).to eq("render")
    end

    it "rejects non-numeric quantile fractions" do
      expect { model.quantile("0.5; DROP TABLE x", :duration_ms) }.to raise_error(ArgumentError)
    end
  end

  describe ".estimated_count" do
    it "reads the table's row estimate from metadata without scanning" do
      expect(model.estimated_count).to eq(20)
    end
  end
end
