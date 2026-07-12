# frozen_string_literal: true

# Phase 3 acceptance corpus (AGENTS.md): TRMNL core's real ClickHouse migrations must run
# verbatim against this adapter, up and back down.
RSpec.describe "TRMNL core migrations corpus" do
  # Mirrors TRMNL core's inflection config so ReduceLogsTTLToFourteenDays resolves.
  ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "TTL" }

  subject(:migration_context) { ActiveRecord::MigrationContext.new(corpus_path) }

  let(:corpus_path) { File.expand_path("../../../core/db/migrate_clickhouse", __dir__) }
  let(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    %w[events logs jobs requests deploys schema_migrations ar_internal_metadata].each do |table|
      conn.drop_table(table, if_exists: true)
    end
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    %w[events logs jobs requests deploys schema_migrations ar_internal_metadata].each do |table|
      conn.drop_table(table, if_exists: true)
    end
  end

  it "runs every migration up and back down verbatim", :aggregate_failures do
    skip "TRMNL core corpus not checked out at #{corpus_path}" unless File.directory?(corpus_path)

    migration_context.migrate
    expect(migration_context.get_all_versions.length).to eq(migration_context.migrations.length)
    expect(connection.tables).to include("events", "logs", "jobs", "requests", "deploys")

    event_type = connection.columns("events").find { |column| column.name == "event_type" }
    expect(event_type.sql_type).to eq("Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4)")

    migration_context.migrate(0)
    expect(migration_context.get_all_versions).to eq([])
    expect(connection.tables).not_to include("events", "logs", "jobs", "requests", "deploys")
  end
end
