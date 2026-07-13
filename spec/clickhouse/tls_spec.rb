# frozen_string_literal: true

# The compose file serves HTTPS on 18443 with the self-signed cert in spec/support/tls,
# mirroring a prod sink that terminates TLS with its own certificate. Verification is ON
# by default (the incumbent adapter hardcoded VERIFY_NONE); ssl_verify: false is the
# explicit escape hatch for self-signed sinks.
RSpec.describe ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection do
  subject(:connection) { described_class.new(tls_config) }

  let(:tls_config) do
    CLICKHOUSE_TEST_CONFIG.merge(
      port: Integer(ENV.fetch("CLICKHOUSE_HTTPS_PORT", 18_443)),
      ssl: true,
      ssl_verify: false
    )
  end

  it "connects to a self-signed TLS server with ssl_verify: false" do
    expect(connection.execute("SELECT 1 AS one").rows).to eq([[1]])
  end

  it "verifies certificates by default, rejecting the self-signed server" do
    verifying = described_class.new(tls_config.except(:ssl_verify))
    expect { verifying.execute("SELECT 1") }.to raise_error(OpenSSL::SSL::SSLError)
  end

  it "passes the ssl options through the adapter's connection-parameter filter" do
    adapter = ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(tls_config)
    expect(adapter.select_value("SELECT 1")).to eq(1)
  end

  it "streams inserts over the unverified TLS session" do
    connection.execute("CREATE TABLE tls_probes (n Int32) ENGINE = MergeTree ORDER BY n")
    connection.execute_stream("INSERT INTO tls_probes (n) FORMAT JSONCompactEachRow", [[1], [2]].map(&:to_json).each)
    expect(connection.execute("SELECT count() FROM tls_probes").rows).to eq([[2]])
  ensure
    connection.execute("DROP TABLE IF EXISTS tls_probes")
  end
end
