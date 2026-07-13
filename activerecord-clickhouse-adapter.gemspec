# frozen_string_literal: true

# No require_relative here: Bundler evaluates this file at bundler/setup time for path/git
# consumers, and defining any ActiveRecord constant that early clobbers active_record.rb's
# `autoload :ConnectionAdapters` (proven in spec/clickhouse/gem_version_spec.rb).
Gem::Specification.new do |spec|
  spec.name = "activerecord-clickhouse-adapter"
  spec.version = "0.1.0"
  spec.authors = ["Ikraam Ghoor"]
  spec.summary = "ClickHouse database adapter for Active Record"
  spec.description = "A fully featured Active Record adapter for ClickHouse: native types, " \
                     "server-side bind parameters, MergeTree-aware migrations, and real " \
                     "instrumentation (read rows/bytes, server elapsed time) on every query."
  spec.homepage = "https://github.com/ikraamg/activerecord-clickhouse-adapter"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "LICENSE*", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 8.1", "< 9.0"
  spec.metadata["rubygems_mfa_required"] = "true"
end
