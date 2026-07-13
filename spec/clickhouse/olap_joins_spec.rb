# frozen_string_literal: true

# ClickHouse's OLAP join grammar: ASOF (nearest-earlier match, the time-series join)
# passes through Rails' raw-string joins untouched; ARRAY JOIN (array unnesting) is new
# grammar and gets a relation method.
RSpec.describe "ClickHouse OLAP joins" do
  subject(:events) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "join_events"

      def self.name = "JoinEvent"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("join_events", if_exists: true)
    conn.drop_table("join_prices", if_exists: true)
    conn.create_table("join_events", order: "(device_id, at)") do |t|
      t.integer :device_id, limit: 8
      t.datetime :at, precision: 6
      t.column :tags, "Array(String)"
    end
    conn.create_table("join_prices", order: "(device_id, at)") do |t|
      t.integer :device_id, limit: 8
      t.datetime :at, precision: 6
      t.integer :price, limit: 8
    end
    conn.execute(<<~SQL.squish)
      INSERT INTO join_events VALUES
        (1, '2026-07-13 10:30:00', ['alpha', 'beta']), (2, '2026-07-13 11:30:00', [])
    SQL
    conn.execute(<<~SQL.squish)
      INSERT INTO join_prices VALUES
        (1, '2026-07-13 10:00:00', 100), (1, '2026-07-13 11:00:00', 200),
        (2, '2026-07-13 11:00:00', 50)
    SQL
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("join_events", if_exists: true)
    conn.drop_table("join_prices", if_exists: true)
  end

  describe "ASOF JOIN via raw-string joins" do
    it "matches each event to the nearest earlier price" do
      prices = events
               .joins(<<~SQL.squish)
                 ASOF LEFT JOIN join_prices ON join_events.device_id = join_prices.device_id
                 AND join_events.at >= join_prices.at
               SQL
               .order(:device_id).pluck(Arel.sql("join_prices.price"))
      expect(prices).to eq([100, 50])
    end
  end

  describe ".array_join" do
    it "unnests one row per array element" do
      tags = events.array_join(:tags).where(device_id: 1).pluck(:tags)
      expect(tags).to eq(%w[alpha beta])
    end

    it "drops rows with empty arrays" do
      expect(events.array_join(:tags).pluck(:device_id)).to eq([1, 1])
    end

    it "keeps empty-array rows with left: true" do
      expect(events.array_join(:tags, left: true).pluck(:device_id).sort).to eq([1, 1, 2])
    end

    it "exposes elements under an alias" do
      tags = events.array_join(:tags, as: :tag).where(device_id: 1).pluck(Arel.sql("tag"))
      expect(tags).to eq(%w[alpha beta])
    end

    it "leaves the original array column addressable when aliased" do
      rows = events.array_join(:tags, as: :tag).where(device_id: 1)
                   .pluck(Arel.sql("tag"), Arel.sql("length(tags)"))
      expect(rows).to eq([["alpha", 2], ["beta", 2]])
    end

    it "composes with where on the unnested element" do
      matches = events.array_join(:tags, as: :tag).where("tag = ?", "beta").pluck(:device_id)
      expect(matches).to eq([1])
    end
  end
end
