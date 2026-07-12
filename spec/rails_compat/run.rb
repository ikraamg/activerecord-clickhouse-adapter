# frozen_string_literal: true

# Runs the vendored Rails Active Record suites (pinned upstream tag recorded in
# vendor/UPSTREAM) against the live ClickHouse adapter. Invoked by
# spec/rails_compat/harness_spec.rb and directly via:
#   bundle exec ruby spec/rails_compat/run.rb

$LOAD_PATH.unshift(File.expand_path("support", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "cases/helper"

Dir[File.expand_path("vendor/cases/*_test.rb", __dir__)].each { |file| require file }
