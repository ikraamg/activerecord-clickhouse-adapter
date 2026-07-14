# frozen_string_literal: true

require "tempfile"

RSpec.describe ActiveRecord::Tasks::ClickHouseDatabaseTasks do
  subject(:tasks) { described_class.new(db_config) }

  let(:scratch_database) { "ar_clickhouse_tasks_scratch" }
  let(:db_config) do
    ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test", "clickhouse_scratch", CLICKHOUSE_TEST_CONFIG.merge(database: scratch_database)
    )
  end
  let(:admin_connection) do
    ActiveRecord::ConnectionAdapters::ClickHouse::HTTPConnection.new(
      CLICKHOUSE_TEST_CONFIG.except(:adapter, :database)
    )
  end

  after do
    admin_connection.execute("DROP DATABASE IF EXISTS #{scratch_database}")
    admin_connection.close
    ActiveRecord::Base.establish_connection(CLICKHOUSE_TEST_CONFIG)
  end

  it "is registered for the clickhouse adapter" do
    expect(ActiveRecord::Tasks::DatabaseTasks.send(:class_for_adapter, "clickhouse")).to eq(described_class)
  end

  it "creates the configured database" do
    tasks.create
    expect(admin_connection.execute("SHOW DATABASES").rows.flatten).to include(scratch_database)
  end

  it "raises DatabaseAlreadyExists when creating twice" do
    tasks.create
    expect { tasks.create }.to raise_error(ActiveRecord::DatabaseAlreadyExists)
  end

  it "drops the configured database" do
    tasks.create
    tasks.drop
    expect(admin_connection.execute("SHOW DATABASES").rows.flatten).not_to include(scratch_database)
  end

  it "raises NoDatabaseError when dropping a missing database" do
    expect { tasks.drop }.to raise_error(ActiveRecord::NoDatabaseError)
  end

  it "purges the database back to empty" do
    tasks.create
    admin_connection.execute("CREATE TABLE #{scratch_database}.leftover (n Int32) ENGINE = MergeTree ORDER BY n")
    tasks.purge
    expect(admin_connection.execute("SHOW TABLES FROM #{scratch_database}").rows).to be_empty
  end

  context "with structure dump and load" do
    let(:structure_path) { Tempfile.create(["structure", ".sql"]).path }

    before do
      tasks.create
      admin_connection.execute(<<~SQL)
        CREATE TABLE #{scratch_database}.events (
          device_id Int64, kind LowCardinality(String) DEFAULT 'none'
        ) ENGINE = MergeTree ORDER BY device_id
      SQL
    end

    after { File.delete(structure_path) }

    it "dumps every data source as SHOW CREATE statements" do
      tasks.structure_dump(structure_path, nil)
      expect(File.read(structure_path)).to include("CREATE TABLE #{scratch_database}.events")
    end

    it "loads the dumped structure into an empty database" do
      tasks.structure_dump(structure_path, nil)
      admin_connection.execute("DROP TABLE #{scratch_database}.events")
      tasks.structure_load(structure_path, nil)
      names = admin_connection.execute("SHOW TABLES FROM #{scratch_database}").rows.flatten
      expect(names).to include("events")
    end

    context "with a dictionary" do
      before do
        admin_connection.execute(<<~SQL.squish)
          CREATE DICTIONARY #{scratch_database}.event_labels (device_id Int64, kind String)
          PRIMARY KEY device_id
          SOURCE(CLICKHOUSE(TABLE 'events' DB '#{scratch_database}' USER 'rails' PASSWORD 'rails'))
          LAYOUT(FLAT()) LIFETIME(MIN 0 MAX 300)
        SQL
      end

      it "hides credentials in the dumped file (the server masks them)" do
        tasks.structure_dump(structure_path, nil)
        expect(File.read(structure_path)).to include("PASSWORD '[HIDDEN]'")
      end

      it "reinjects the connection credentials on load so dictGet still authenticates" do
        tasks.structure_dump(structure_path, nil)
        admin_connection.execute("DROP DICTIONARY #{scratch_database}.event_labels")
        admin_connection.execute("DROP TABLE #{scratch_database}.events")
        tasks.structure_load(structure_path, nil)
        admin_connection.execute("INSERT INTO #{scratch_database}.events VALUES (1, 'boot')")
        value = admin_connection.execute(
          "SELECT dictGet('#{scratch_database}.event_labels', 'kind', toUInt64(1))"
        ).rows.flatten.first
        expect(value).to eq("boot")
      end
    end
  end
end
