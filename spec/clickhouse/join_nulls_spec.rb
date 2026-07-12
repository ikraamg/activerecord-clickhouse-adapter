# frozen_string_literal: true

# ClickHouse fills non-matched outer-join columns with type defaults (0, '') unless
# join_use_nulls=1. Every other Active Record adapter returns SQL-standard NULLs, and
# aggregates over LEFT JOINs silently miscount otherwise, so the adapter defaults to 1
# (probed 2026-07-12; override with join_use_nulls: 0 in the config).
RSpec.describe "ClickHouse outer join NULL semantics" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  let(:unmatched_join_sql) do
    <<~SQL.squish
      SELECT t2.m AS unmatched FROM (SELECT 1 AS n) t1
      LEFT JOIN (SELECT 2 AS n, 5 AS m) t2 ON t1.n = t2.n
    SQL
  end

  it "returns NULL for non-matched left join columns" do
    expect(connection.select_value(unmatched_join_sql)).to be_nil
  end

  context "when join_use_nulls is disabled in the config" do
    subject(:raw_connection) do
      ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection.new(
        CLICKHOUSE_TEST_CONFIG.except(:adapter).merge(join_use_nulls: 0)
      )
    end

    after { raw_connection.close }

    it "restores the ClickHouse default-value behavior" do
      expect(raw_connection.execute(unmatched_join_sql).rows).to eq([[0]])
    end
  end
end
