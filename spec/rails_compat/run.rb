# frozen_string_literal: true

# Runs the vendored Rails Active Record suites (pinned upstream tag recorded in
# vendor/UPSTREAM) against the live ClickHouse adapter. Invoked by
# spec/rails_compat/harness_spec.rb and directly via:
#   bundle exec ruby spec/rails_compat/run.rb

$LOAD_PATH.unshift(File.expand_path("vendor", __dir__))
$LOAD_PATH.unshift(File.expand_path("support", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))

require "cases/helper"
require "schema_slice"

ARCompat::SchemaSlice.load(ActiveRecord::Base.lease_connection)

Dir[File.expand_path("vendor/cases/**/*_test.rb", __dir__)].each { |file| require file }

ARCompat.apply_suite_exclusions
ARCompat::SchemaSlice.assign_model_primary_keys
