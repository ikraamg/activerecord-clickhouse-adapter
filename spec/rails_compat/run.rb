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

# Upstream's test database is prepared by a rake task that leaves both migration
# infrastructure tables in place; several MigrationTest cases (internal metadata
# reads/deletes) assume they exist rather than creating them — seed-order latent
# otherwise, because only *some* MigrationTest tests create them as a side effect.
ActiveRecord::Base.connection_pool.schema_migration.create_table
ActiveRecord::Base.connection_pool.internal_metadata.create_table

Dir[File.expand_path("vendor/cases/**/*_test.rb", __dir__)].each { |file| require file }

ARCompat.apply_suite_exclusions
ARCompat::SchemaSlice.assign_model_primary_keys

# The pid stamp caught the "double-summary flake" red-handed (Iteration 36): two
# concurrent full gates whose harness subprocesses shared one database and one
# redirect file. Databases are pid-suffixed now; the stamp stays so any future
# shared-output collision identifies both writers immediately.
Minitest.after_run { warn "rails-compat harness summary from pid #{Process.pid}" }
