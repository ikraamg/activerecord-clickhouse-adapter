# frozen_string_literal: true

require "open3"

# The Phase 6 rails-compat ratchet: vendored upstream Active Record suites must pass
# against the live adapter, with any skip documented in skips.yml.
RSpec.describe "Rails compat harness" do
  subject(:run) do
    Open3.capture2e(
      { "RUBYOPT" => nil },
      RbConfig.ruby, File.expand_path("run.rb", __dir__),
      chdir: File.expand_path("../..", __dir__)
    )
  end

  it "passes every vendored upstream test or documents the skip" do
    output, status = run
    expect(status).to be_success, output
  end
end
