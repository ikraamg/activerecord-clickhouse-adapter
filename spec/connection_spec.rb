# frozen_string_literal: true

RSpec.describe "ClickHouse connection", :aggregate_failures do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "identifies itself by adapter name" do
    expect(connection.adapter_name).to eq("ClickHouse")
  end

  it "answers a live SELECT with a typed Ruby integer" do
    expect(connection.select_value("SELECT 1")).to eq(1)
  end

  # Connecting is lazy: a virgin connection has no raw socket yet and active? is
  # honestly false until something materializes it (order-dependent under random
  # seeds otherwise) — verify! is Rails' own establish-or-reconnect seam.
  it "reports the live server as active" do
    connection.verify!
    expect(connection).to be_active
  end

  it "exposes the real server version" do
    expect(connection.database_version.to_s).to match(/\A\d+\.\d+/)
  end

  # Rails installs a real Monitor via lock_thread when a connection is shared across
  # threads (transactional-test pinning). Queries hold that lock for their whole
  # round-trip (with_raw_connection), so disconnect! must close the socket while
  # still holding it — closing after release lets a queued query start its HTTP
  # read on a socket that dies mid-flight (IOError; seen live in the vendored
  # AdapterThreadSafetyTest). Same pattern as the postgresql adapter's disconnect!.
  it "closes the raw connection while still holding the adapter lock" do
    dedicated = ActiveRecord::Base.connection_pool.checkout
    dedicated.lock_thread = Fiber.current
    dedicated.select_value("SELECT 1")
    lock = dedicated.instance_variable_get(:@lock)
    lock_held_at_close = nil
    dedicated.instance_variable_get(:@raw_connection).define_singleton_method(:close) do
      lock_held_at_close = lock.mon_owned?
      super()
    end
    dedicated.disconnect!
    expect(lock_held_at_close).to be(true)
  ensure
    ActiveRecord::Base.connection_pool.remove(dedicated)
    dedicated&.disconnect!
  end
end
