# frozen_string_literal: true

require "open3"

# The examples directory is living documentation: the OLAP-on-Rails tour must
# keep running end-to-end against the same live server as the rest of the suite.
RSpec.describe "OLAP on Rails example" do
  subject(:run) do
    Open3.capture2e(
      { "RUBYOPT" => nil, "CLICKHOUSE_DATABASE" => "ar_clickhouse_example" },
      RbConfig.ruby, File.expand_path("../../examples/olap_on_rails.rb", __dir__),
      chdir: File.expand_path("../..", __dir__)
    )
  end

  before do
    ActiveRecord::Base.lease_connection.execute("CREATE DATABASE IF NOT EXISTS ar_clickhouse_example")
  end

  it "runs the whole tour against the live server" do
    output, status = run
    expect(status).to be_success, output
  end
end
