# frozen_string_literal: true

RSpec.describe "ClickHouse migration flow" do
  subject(:migration_context) do
    ActiveRecord::MigrationContext.new(SPEC_ROOT.join("fixtures", "migrations").to_s)
  end

  let(:connection) { ActiveRecord::Base.lease_connection }

  before do
    connection.drop_table("flow_probe", if_exists: true)
    connection.drop_table("schema_migrations", if_exists: true)
    connection.drop_table("ar_internal_metadata", if_exists: true)
  end

  after do
    connection.drop_table("flow_probe", if_exists: true)
    connection.drop_table("schema_migrations", if_exists: true)
    connection.drop_table("ar_internal_metadata", if_exists: true)
  end

  it "migrates from zero and records both versions" do
    migration_context.migrate
    expect(migration_context.get_all_versions).to eq([1, 2])
  end

  it "creates the migrated table with all columns" do
    migration_context.migrate
    expect(connection.columns("flow_probe").map(&:name)).to eq(%w[device_id ts tag note])
  end

  it "creates schema_migrations as an append-safe ReplacingMergeTree" do
    migration_context.migrate
    engine = connection.select_value(
      "SELECT engine FROM system.tables WHERE database = currentDatabase() AND name = 'schema_migrations'"
    )
    expect(engine).to eq("ReplacingMergeTree")
  end

  it "records the environment in ar_internal_metadata" do
    migration_context.migrate
    value = connection.select_value("SELECT value FROM ar_internal_metadata FINAL WHERE key = 'environment'")
    expect(value).to eq(ActiveRecord::Base.connection_pool.db_config.env_name)
  end

  it "is idempotent on re-migrate" do
    migration_context.migrate
    expect { migration_context.migrate }.not_to change(migration_context, :get_all_versions)
  end

  it "rolls back the latest migration and deletes its version" do
    migration_context.migrate
    migration_context.rollback(1)
    expect(migration_context.get_all_versions).to eq([1])
  end

  it "removes rolled-back columns from the table" do
    migration_context.migrate
    migration_context.rollback(1)
    expect(connection.column_exists?("flow_probe", "note")).to be(false)
  end
end
