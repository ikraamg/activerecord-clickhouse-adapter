# frozen_string_literal: true

# Bundler evaluates the gemspec of a path-sourced gem at bundler/setup time, before Rails
# loads. If the version file defines any ActiveRecord constant then, active_record.rb's
# `autoload :ConnectionAdapters` silently no-ops and the first consumer that requires a
# connection-adapter file crashes (discovered live porting TRMNL core:
# `uninitialized constant SqlTypeMetadata::Deduplicable`).
RSpec.describe "gemspec namespace isolation" do
  subject(:subprocess_output) do
    gemspec_path = File.expand_path("../../activerecord-clickhouse-adapter.gemspec", __dir__)
    script = <<~RUBY
      load #{gemspec_path.inspect}
      print "gemspec leaked ActiveRecord; " if defined?(ActiveRecord)
      require "active_record"
      print ActiveRecord.autoload?(:ConnectionAdapters) ? "autoload intact" : "autoload clobbered"
    RUBY
    IO.popen({ "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }, [RbConfig.ruby, "-e", script], err: %i[child out], &:read)
  end

  it "leaves ActiveRecord's autoload chain intact after evaluating the gemspec" do
    expect(subprocess_output).to eq("autoload intact")
  end

  it "keeps the gemspec version in step with the runtime VERSION constant" do
    gemspec = Gem::Specification.load(File.expand_path("../../activerecord-clickhouse-adapter.gemspec", __dir__))
    expect(gemspec.version.to_s).to eq(ActiveRecord::ConnectionAdapters::ClickHouse::VERSION)
  end
end
