# frozen_string_literal: true

RSpec.describe "ClickHouse dialect relation extensions" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "dialect_probe"

      def self.name = "DialectProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("dialect_probe", if_exists: true)
    conn.execute(<<~SQL.squish)
      CREATE TABLE dialect_probe (k UInt64, v String)
      ENGINE = ReplacingMergeTree
      ORDER BY (k, sipHash64(k))
      SAMPLE BY sipHash64(k)
    SQL
    conn.execute("INSERT INTO dialect_probe SELECT number, 'first' FROM numbers(100)")
    conn.execute("INSERT INTO dialect_probe VALUES (1, 'second')")
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("dialect_probe", if_exists: true)
  end

  describe ".final" do
    it "collapses ReplacingMergeTree duplicates" do
      expect(model.final.count).to eq(100)
    end

    it "sees duplicates without final" do
      expect(model.count).to eq(101)
    end

    it "keeps the replacing row's value" do
      expect(model.final.where(k: 1).pluck(:v)).to eq(["second"])
    end

    it "chains after where" do
      expect(model.where(k: 1).final.count).to eq(1)
    end
  end

  describe ".sample" do
    it "reads roughly the requested fraction" do
      expect(model.sample(0.5).count).to be_between(1, 100)
    end

    it "composes with final" do
      expect(model.final.sample(1.0).count).to eq(100)
    end
  end

  describe ".prewhere" do
    it "filters rows before the main WHERE (duplicate k=1 row still visible without final)" do
      expect(model.prewhere("k < 10").where(v: "first").count).to eq(10)
    end

    it "sanitizes array conditions" do
      expect(model.prewhere(["k < ?", 5]).count).to eq(6)
    end

    it "renders PREWHERE between FROM and WHERE" do
      sql = model.prewhere("k < 10").where(v: "first").to_sql
      expect(sql).to include("FROM `dialect_probe` PREWHERE k < 10 WHERE")
    end
  end

  describe ".settings" do
    it "appends a trailing SETTINGS clause" do
      expect(model.settings(max_threads: 1).count).to eq(101)
    end

    it "renders SETTINGS after LIMIT in SQL" do
      sql = model.settings(max_threads: 1).limit(5).to_sql
      expect(sql).to match(/LIMIT 5 SETTINGS max_threads = 1\z/)
    end

    it "rejects unsafe setting names" do
      expect { model.settings("bad name" => 1).to_sql }.to raise_error(ArgumentError)
    end
  end

  describe ".limit_by" do
    it "limits per group" do
      expect(model.limit_by(1, :k).pluck(:k).length).to eq(100)
    end

    it "renders LIMIT n BY between ORDER BY and LIMIT" do
      sql = model.order(:k).limit_by(1, :k).limit(5).to_sql
      expect(sql).to match(/ORDER BY .* LIMIT 1 BY `k` LIMIT 5\z/)
    end

    # Ported from ../clickhouse/tests/queries/0_stateless/00409_shard_limit_by.sql —
    # k=1 exists with two v values, so LIMIT 1 BY (k, v) keeps both rows.
    it "combines multi-column LIMIT BY with LIMIT like the upstream oracle" do
      rows = model.order(:k).limit_by(1, :k, :v).limit(3).pluck(:k)
      expect(rows).to eq([0, 1, 1])
    end
  end

  describe "#explain" do
    it "returns the server's query plan" do
      expect(model.where(k: 1).explain.inspect).to include("ReadFromMergeTree")
    end

    it "supports the indexes variant showing primary-key pruning" do
      expect(model.where(k: 1).explain(:indexes).inspect).to include("PrimaryKey")
    end

    it "supports the estimate variant" do
      expect(model.all.explain(:estimate).inspect).to include("parts")
    end

    it "supports the pipeline variant" do
      expect(model.all.explain(:pipeline).inspect).to include("MergeTree")
    end
  end
end
