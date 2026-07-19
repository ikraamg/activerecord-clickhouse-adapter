# frozen_string_literal: true

# Multi-replica support: `hosts:` lists interchangeable HTTP endpoints
# ("host" or "host:port", the port: key is the default). Each new connection
# starts one endpoint further along (round-robin across a pool), sticks to a
# healthy endpoint for keep-alive, and rotates only on connect-phase failures —
# errors that guarantee the request never reached a server, so retrying can
# never double a write. Mid-flight failures (read timeouts) raise instead.
RSpec.describe ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection do
  subject(:connection) { described_class.new(config) }

  let(:live_port) { CLICKHOUSE_TEST_CONFIG[:port] }
  # Port 9 (discard) is unbound in the test container's port map: connecting is
  # refused immediately, so failover specs never wait on a timeout.
  let(:dead_endpoint) { "localhost:9" }
  let(:config) { CLICKHOUSE_TEST_CONFIG.merge(hosts: hosts) }

  describe "failover" do
    let(:hosts) { [dead_endpoint, "localhost:#{live_port}"] }

    before { connection.instance_variable_set(:@endpoint_index, 0) }

    it "answers through the next host when the first refuses the connection" do
      expect(connection.execute("SELECT 1 AS one").rows).to eq([[1]])
    end

    it "lands on the live endpoint" do
      connection.execute("SELECT 1")
      expect(connection.current_endpoint).to eq("localhost:#{live_port}")
    end

    it "stays on the live endpoint for subsequent queries" do
      connection.execute("SELECT 1")
      connection.execute("SELECT 2")
      expect(connection.current_endpoint).to eq("localhost:#{live_port}")
    end

    it "walks past several dead hosts in one call" do
      multi = described_class.new(config.merge(hosts: [dead_endpoint, dead_endpoint, "localhost:#{live_port}"]))
      multi.instance_variable_set(:@endpoint_index, 0)
      expect(multi.execute("SELECT 1 AS one").rows).to eq([[1]])
    end

    it "raises once every endpoint has refused" do
      all_dead = described_class.new(config.merge(hosts: [dead_endpoint, dead_endpoint]))
      expect { all_dead.execute("SELECT 1") }.to raise_error(Errno::ECONNREFUSED)
    end
  end

  describe "round-robin start positions" do
    let(:hosts) { ["localhost:#{live_port}", "127.0.0.1:#{live_port}"] }

    it "starts consecutive connections on different endpoints" do
      first = described_class.new(config)
      second = described_class.new(config)
      expect(first.current_endpoint).not_to eq(second.current_endpoint)
    end
  end

  describe "mid-flight failures" do
    let(:hosts) { ["localhost:#{live_port}", "127.0.0.1:#{live_port}"] }
    let(:config) { CLICKHOUSE_TEST_CONFIG.merge(hosts: hosts, read_timeout: 1) }

    it "raises instead of replaying the request on another replica" do
      expect { connection.execute("SELECT sleep(3)") }.to raise_error(Net::ReadTimeout)
    end

    it "keeps the endpoint it was on" do
      before_endpoint = connection.current_endpoint
      begin
        connection.execute("SELECT sleep(3)")
      rescue Net::ReadTimeout
        nil
      end
      expect(connection.current_endpoint).to eq(before_endpoint)
    end
  end

  describe "single-host configs" do
    subject(:connection) { described_class.new(CLICKHOUSE_TEST_CONFIG) }

    it "reports the host: and port: keys as the endpoint" do
      expect(connection.current_endpoint).to eq("#{CLICKHOUSE_TEST_CONFIG[:host]}:#{live_port}")
    end
  end

  describe "through the adapter" do
    subject(:adapter) do
      ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(
        CLICKHOUSE_TEST_CONFIG.merge(hosts: [dead_endpoint, "localhost:#{live_port}"])
      )
    end

    it "passes hosts through the connection-parameter filter" do
      expect(adapter.select_value("SELECT 1")).to eq(1)
    end
  end
end
