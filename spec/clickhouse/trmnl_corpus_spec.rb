# frozen_string_literal: true

# Phase 3 acceptance corpus (AGENTS.md): TRMNL core's real ClickHouse migrations must run
# verbatim against this adapter, up and back down. The live ../core checkout wins when
# present (catches drift before the snapshot goes stale); CI runs the vendored snapshot
# (spec/vendor/trmnl_corpus, see its UPSTREAM file).
RSpec.describe "TRMNL core migrations corpus" do
  # Mirrors TRMNL core's inflection config so ReduceLogsTTLToFourteenDays resolves.
  ActiveSupport::Inflector.inflections(:en) { |inflect| inflect.acronym "TTL" }

  subject(:migration_context) { ActiveRecord::MigrationContext.new(corpus_path) }

  let(:checkout_path) { File.expand_path("../../../core/db/migrate_clickhouse", __dir__) }

  let(:corpus_path) do
    File.directory?(checkout_path) ? checkout_path : File.expand_path("../vendor/trmnl_corpus", __dir__)
  end
  let(:connection) { ActiveRecord::Base.lease_connection }

  def corpus_tables = %w[events logs jobs requests deploys fetches pool_events process_health]

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    (corpus_tables + %w[schema_migrations ar_internal_metadata]).each do |table|
      conn.drop_table(table, if_exists: true)
    end
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    (corpus_tables + %w[schema_migrations ar_internal_metadata]).each do |table|
      conn.drop_table(table, if_exists: true)
    end
  end

  it "runs every migration up and back down verbatim", :aggregate_failures do
    migration_context.migrate
    expect(migration_context.get_all_versions.length).to eq(migration_context.migrations.length)
    expect(connection.tables).to include(*corpus_tables)

    event_type = connection.columns("events").find { |column| column.name == "event_type" }
    expect(event_type.sql_type)
      .to eq("Enum8('checkin' = 1, 'schedule' = 2, 'render' = 3, 'serve' = 4, " \
             "'ingest' = 5, 'setup' = 6, 'reset' = 7, 'oauth' = 8)")

    migration_context.migrate(0)
    expect(migration_context.get_all_versions).to eq([])
    expect(connection.tables).not_to include(*corpus_tables)
  end

  it "round-trips the migrated schema through the dumper" do
    tables = corpus_tables
    ActiveRecord::SchemaDumper.ignore_tables = [->(table) { tables.exclude?(table) }]
    migration_context.migrate
    first_dump = dump_schema
    corpus_tables.each { |table| connection.drop_table(table) }
    eval(first_dump) # rubocop:disable Security/Eval -- loading the dump is the point
    expect(dump_schema).to eq(first_dump)
  ensure
    ActiveRecord::SchemaDumper.ignore_tables = []
    migration_context.migrate(0)
  end

  def dump_schema
    ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, StringIO.new).string
  end
end
