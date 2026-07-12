# frozen_string_literal: true

# Server gzips responses when enable_http_compression=1 (probed 2026-07-12: 789 KB → 216 KB
# on a 100k-row select); Net::HTTP decompresses transparently, including error bodies.
RSpec.describe ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection do
  subject(:connection) { described_class.new(CLICKHOUSE_TEST_CONFIG) }

  after { connection.close }

  it "returns intact rows on a large compressed result" do
    result = connection.execute("SELECT number FROM numbers(100000)")
    expect(result.rows.last).to eq([99_999])
  end

  it "decodes compressed error bodies into readable messages" do
    expect { connection.execute("SELECT nope FROM system.one") }
      .to raise_error(described_class::ExecutionError, /UNKNOWN_IDENTIFIER/)
  end

  context "when compression is disabled" do
    subject(:connection) { described_class.new(CLICKHOUSE_TEST_CONFIG.merge(compression: false)) }

    it "still returns intact rows" do
      result = connection.execute("SELECT number FROM numbers(100000)")
      expect(result.rows.last).to eq([99_999])
    end
  end
end
