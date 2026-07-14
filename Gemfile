# frozen_string_literal: true

source "https://rubygems.org"

gemspec

# RAILS_SOURCE=edge runs the suite against Rails main: the local rails-main worktree
# when present (kept fresh via `git -C ../rails-main fetch origin main`), the GitHub
# monorepo otherwise (CI). Default is the released gem.
# rubocop:disable Bundler/DuplicatedGem -- edge branches are mutually exclusive
if ENV["RAILS_SOURCE"] == "edge"
  if Dir.exist?(File.expand_path("../rails-main/activerecord", __dir__))
    gem "activemodel", path: "../rails-main/activemodel"
    gem "activerecord", path: "../rails-main/activerecord"
    gem "activesupport", path: "../rails-main/activesupport"
  else
    git "https://github.com/rails/rails.git", branch: "main" do
      gem "activemodel"
      gem "activerecord"
      gem "activesupport"
    end
  end
end
# rubocop:enable Bundler/DuplicatedGem

group :development, :test do
  # models/user in the vendored association suites declares has_secure_password.
  gem "bcrypt", require: false
  gem "benchmark-ips"
  # to_xml in the vendored relations_test serializes through Builder, as upstream does.
  gem "builder", require: false
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
