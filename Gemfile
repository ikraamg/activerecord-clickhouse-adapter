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
  gem "rake"
  gem "rspec"
  gem "rubocop", require: false
  gem "rubocop-rspec", require: false
end
