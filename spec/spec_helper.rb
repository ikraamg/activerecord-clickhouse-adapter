# frozen_string_literal: true

require "activerecord-clickhouse-adapter"

SPEC_ROOT = Pathname.new(__dir__)

# Real server only — no mocks. Boot it with: docker compose up -d --wait
CLICKHOUSE_TEST_CONFIG = {
  adapter: "clickhouse",
  host: ENV.fetch("CLICKHOUSE_HOST", "localhost"),
  port: Integer(ENV.fetch("CLICKHOUSE_HTTP_PORT", 18_123)),
  username: ENV.fetch("CLICKHOUSE_USER", "rails"),
  password: ENV.fetch("CLICKHOUSE_PASSWORD", "rails"),
  database: ENV.fetch("CLICKHOUSE_DATABASE", "ar_clickhouse_test")
}.freeze

ActiveRecord::Base.establish_connection(CLICKHOUSE_TEST_CONFIG)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
