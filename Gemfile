# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# RAILS_SOURCE=edge runs the suite against the local rails-main worktree
# (kept fresh via `git -C ../rails fetch origin main`); default is the released gem.
gem "activerecord", path: "../rails-main/activerecord" if ENV["RAILS_SOURCE"] == "edge"

group :development, :test do
  gem "benchmark-ips"
  gem "debug"
  gem "memory_profiler"
  # Runs the vendored Rails AR suites in spec/rails_compat; 5.x because Rails 8.1's
  # test helpers require minitest/mock, extracted to a separate gem in minitest 6.
  gem "minitest", "~> 5.25", require: false
  gem "rake"
  gem "rspec"
  gem "rubocop", require: false
  gem "rubocop-rspec", require: false
end
