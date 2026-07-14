# frozen_string_literal: true

# Dictionaries are ClickHouse's in-memory lookup tables; dictGet replaces the
# dimension JOIN of a star schema. Probed live 2026-07-14: the dictionary's own
# source connection authenticates separately (as `default` unless SOURCE carries
# USER/PASSWORD), so create_dictionary injects the adapter's credentials.
RSpec.describe "ClickHouse dictionaries" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP DICTIONARY IF EXISTS device_labels")
    conn.drop_table("dict_devices", if_exists: true)
    # FLAT-layout dictionary keys must be UInt64, which the Rails DSL never emits.
    conn.execute("CREATE TABLE dict_devices (id UInt64, label String) ENGINE = MergeTree ORDER BY id")
    conn.execute("INSERT INTO dict_devices VALUES (1, 'kitchen'), (2, 'hallway')")
    conn.create_dictionary("device_labels", source: "dict_devices", primary_key: :id)
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP DICTIONARY IF EXISTS device_labels")
    conn.drop_table("dict_devices", if_exists: true)
  end

  describe "#create_dictionary" do
    it "creates a queryable dictionary with columns inferred from the source table" do
      expect(connection.select_value("SELECT dictGet('device_labels', 'label', toUInt64(1))")).to eq("kitchen")
    end

    it "registers the dictionary in the catalog" do
      expect(connection.dictionaries).to include("device_labels")
    end

    it "renders an explicit layout" do
      connection.create_dictionary("device_labels_hashed", source: "dict_devices", primary_key: :id,
                                                           layout: :hashed, lifetime: 0)
      expect(connection.select_value("SELECT dictGet('device_labels_hashed', 'label', toUInt64(2))")).to eq("hallway")
    ensure
      connection.execute("DROP DICTIONARY IF EXISTS device_labels_hashed")
    end
  end

  describe "#create_dictionary with a cross-database source" do
    before do
      connection.execute("CREATE DATABASE IF NOT EXISTS ar_clickhouse_dims")
      connection.execute(<<~SQL.squish)
        CREATE TABLE ar_clickhouse_dims.remote_devices (id UInt64, label String)
        ENGINE = MergeTree ORDER BY id
      SQL
      connection.execute("INSERT INTO ar_clickhouse_dims.remote_devices VALUES (1, 'roof')")
    end

    after do
      connection.execute("DROP DICTIONARY IF EXISTS cross_db_labels")
      connection.execute("DROP DATABASE IF EXISTS ar_clickhouse_dims")
    end

    it "reads the source from the named database" do
      connection.create_dictionary("cross_db_labels", source: "remote_devices",
                                                      database: "ar_clickhouse_dims", primary_key: :id)
      expect(connection.select_value("SELECT dictGet('cross_db_labels', 'label', toUInt64(1))")).to eq("roof")
    end
  end

  describe "#drop_dictionary" do
    it "removes the dictionary" do
      connection.create_dictionary("doomed_labels", source: "dict_devices", primary_key: :id)
      connection.drop_dictionary("doomed_labels")
      expect(connection.dictionaries).not_to include("doomed_labels")
    end

    it "tolerates a missing dictionary with if_exists" do
      expect { connection.drop_dictionary("never_existed", if_exists: true) }.not_to raise_error
    end
  end

  describe "#reload_dictionary" do
    it "picks up source rows written after the first load" do
      connection.select_value("SELECT dictGet('device_labels', 'label', toUInt64(1))")
      connection.execute("INSERT INTO dict_devices VALUES (3, 'attic')")
      connection.reload_dictionary("device_labels")
      expect(connection.select_value("SELECT dictGet('device_labels', 'label', toUInt64(3))")).to eq("attic")
    end
  end

  describe ".dict_get" do
    subject(:model) do
      Class.new(ActiveRecord::Base) do
        include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

        self.table_name = "dict_readings"

        def self.name = "DictReading"
      end
    end

    before(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.drop_table("dict_readings", if_exists: true)
      conn.execute(<<~SQL.squish)
        CREATE TABLE dict_readings (id Int64, device_id UInt64, battery Int64)
        ENGINE = MergeTree ORDER BY id
      SQL
      conn.execute("INSERT INTO dict_readings VALUES (1, 1, 90), (2, 2, 80), (3, 9, 70)")
    end

    after(:all) do
      ActiveRecord::Base.lease_connection.drop_table("dict_readings", if_exists: true)
    end

    it "projects the looked-up attribute under its own name" do
      row = model.dict_get("device_labels", :label, key: :device_id).order(:id).first
      expect(row[:label]).to eq("kitchen")
    end

    it "keeps the model's own columns selected" do
      row = model.dict_get("device_labels", :label, key: :device_id).order(:id).first
      expect(row.battery).to eq(90)
    end

    it "renames the projection with as:" do
      row = model.dict_get("device_labels", :label, key: :device_id, as: :room).order(:id).first
      expect(row[:room]).to eq("kitchen")
    end

    it "answers default: for keys the dictionary does not know" do
      row = model.dict_get("device_labels", :label, key: :device_id, default: "unknown").order(id: :desc).first
      expect(row[:label]).to eq("unknown")
    end

    it "composes with where scopes" do
      rows = model.where(battery: 80..).dict_get("device_labels", :label, key: :device_id).order(:id)
      expect(rows.map { |row| row[:label] }).to eq(%w[kitchen hallway])
    end

    it "rejects aliases that are not identifiers" do
      expect { model.dict_get("device_labels", :label, key: :device_id, as: "x; DROP TABLE y") }
        .to raise_error(ArgumentError, /alias/)
    end
  end
end
