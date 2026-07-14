# frozen_string_literal: true

RSpec.describe "ClickHouse schema statements" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute(<<~SQL.squish)
      CREATE TABLE IF NOT EXISTS schema_probe (
        device_id UInt64,
        ts        DateTime64(3, 'UTC') DEFAULT now64(3),
        note      Nullable(String),
        tag       LowCardinality(String) DEFAULT 'none',
        active    Bool DEFAULT true,
        INDEX idx_note note TYPE bloom_filter GRANULARITY 4
      )
      ENGINE = MergeTree
      PARTITION BY toDate(ts)
      ORDER BY (device_id, ts)
    SQL
    conn.execute("CREATE VIEW IF NOT EXISTS schema_probe_view AS SELECT device_id FROM schema_probe")
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.execute("DROP VIEW IF EXISTS schema_probe_view")
    conn.execute("DROP TABLE IF EXISTS schema_probe")
  end

  it "lists base tables without views" do
    expect(connection.tables).to include("schema_probe")
    expect(connection.tables).not_to include("schema_probe_view")
  end

  it "lists views" do
    expect(connection.views).to include("schema_probe_view")
  end

  it "confirms table existence" do
    expect(connection.table_exists?("schema_probe")).to be(true)
    expect(connection.table_exists?("nope_not_here")).to be(false)
  end

  it "returns column objects with ClickHouse sql types" do
    ts = connection.columns("schema_probe").find { |column| column.name == "ts" }
    expect(ts.sql_type).to eq("DateTime64(3, 'UTC')")
  end

  it "maps integer columns to :integer" do
    device_id = connection.columns("schema_probe").find { |column| column.name == "device_id" }
    expect(device_id.type).to eq(:integer)
  end

  it "marks Nullable columns as null and bare columns as not null" do
    columns = connection.columns("schema_probe").index_by(&:name)
    expect(columns.fetch("note").null).to be(true)
    expect(columns.fetch("device_id").null).to be(false)
  end

  it "sees through LowCardinality for the AR type" do
    tag = connection.columns("schema_probe").find { |column| column.name == "tag" }
    expect(tag.type).to eq(:string)
  end

  it "captures DEFAULT expressions as default_function" do
    ts = connection.columns("schema_probe").find { |column| column.name == "ts" }
    expect(ts.default_function).to eq("now64(3)")
  end

  it "captures literal defaults as values" do
    tag = connection.columns("schema_probe").find { |column| column.name == "tag" }
    expect(tag.default).to eq("none")
  end

  # A boolean default is a literal, not a function: auto_populated? must stay false
  # or Rails asks for the column back via RETURNING (which ClickHouse lacks).
  it "captures boolean defaults as cast values" do
    active = connection.columns("schema_probe").find { |column| column.name == "active" }
    expect(active.default).to be(true)
  end

  it "leaves boolean defaults out of default_function" do
    active = connection.columns("schema_probe").find { |column| column.name == "active" }
    expect(active.default_function).to be_nil
  end

  it "lists data skipping indexes" do
    index = connection.indexes("schema_probe").first
    expect(index.name).to eq("idx_note")
  end

  it "renames a table keeping its rows" do
    connection.create_table("rename_probe", force: true, order: "id") { |t| t.integer :id, limit: 8 }
    connection.execute("INSERT INTO rename_probe VALUES (7)")
    connection.rename_table("rename_probe", "renamed_probe")
    expect(connection.select_value("SELECT id FROM renamed_probe")).to eq(7)
  ensure
    connection.drop_table("rename_probe", if_exists: true)
    connection.drop_table("renamed_probe", if_exists: true)
  end

  it "reports no Active Record primary key (ClickHouse sorting keys are not unique)" do
    expect(connection.primary_keys("schema_probe")).to eq([])
  end

  describe "projections" do
    before(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.create_table("projection_probe", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.integer :duration_ms, limit: 8
      end
    end

    after(:all) do
      ActiveRecord::Base.lease_connection.drop_table("projection_probe", if_exists: true)
    end

    def projection_names
      connection.select_values(
        "SELECT name FROM system.projections WHERE database = currentDatabase() AND table = 'projection_probe'"
      )
    end

    it "adds a projection with an alternate sort order" do
      connection.add_projection("projection_probe", "by_duration", order: "duration_ms")
      expect(projection_names).to include("by_duration")
    ensure
      connection.drop_projection("projection_probe", "by_duration", if_exists: true)
    end

    it "materializes a projection over existing parts" do
      connection.execute("INSERT INTO projection_probe VALUES (1, 10)")
      connection.add_projection("projection_probe", "by_duration", order: "duration_ms")
      expect { connection.materialize_projection("projection_probe", "by_duration") }.not_to raise_error
    ensure
      connection.drop_projection("projection_probe", "by_duration", if_exists: true)
    end

    it "drops a projection" do
      connection.add_projection("projection_probe", "by_duration", order: "duration_ms")
      connection.drop_projection("projection_probe", "by_duration")
      expect(projection_names).to be_empty
    end

    it "projects an aggregation when given select" do
      connection.add_projection("projection_probe", "totals", select: "sum(duration_ms)", group: "id")
      expect(projection_names).to include("totals")
    ensure
      connection.drop_projection("projection_probe", "totals", if_exists: true)
    end
  end

  describe "optimize_table" do
    it "forces a merge without raising" do
      connection.create_table("optimize_probe", force: true, order: "id") { |t| t.integer :id, limit: 8 }
      connection.execute("INSERT INTO optimize_probe VALUES (1)")
      expect { connection.optimize_table("optimize_probe") }.not_to raise_error
    ensure
      connection.drop_table("optimize_probe", if_exists: true)
    end

    it "deduplicates ReplacingMergeTree rows with final" do
      connection.create_table("optimize_dedup", force: true, engine: "ReplacingMergeTree", order: "id") do |t|
        t.integer :id, limit: 8
      end
      connection.execute("INSERT INTO optimize_dedup VALUES (1)")
      connection.execute("INSERT INTO optimize_dedup VALUES (1)")
      connection.optimize_table("optimize_dedup")
      expect(connection.select_value("SELECT count() FROM optimize_dedup")).to eq(1)
    ensure
      connection.drop_table("optimize_dedup", if_exists: true)
    end
  end

  describe "change_column_default" do
    before(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.create_table("default_probe", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.string :status, default: "old"
      end
    end

    after(:all) do
      ActiveRecord::Base.lease_connection.drop_table("default_probe", if_exists: true)
    end

    it "replaces a literal default" do
      connection.change_column_default("default_probe", "status", "new")
      expect(connection.columns("default_probe").find { |c| c.name == "status" }.default).to eq("new")
    ensure
      connection.change_column_default("default_probe", "status", "old")
    end

    it "removes the default when given nil" do
      connection.change_column_default("default_probe", "status", nil)
      expect(connection.columns("default_probe").find { |c| c.name == "status" }.default).to be_nil
    ensure
      connection.change_column_default("default_probe", "status", "old")
    end
  end

  describe "#create_join_table" do
    after do
      connection.drop_table("musicians_songs", if_exists: true)
    end

    it "defaults the sorting key to the two reference columns" do
      connection.create_join_table(:musicians, :songs)
      expect(connection.table_options("musicians_songs")[:order]).to eq("(musician_id, song_id)")
    end

    it "keeps an explicit order option" do
      connection.create_join_table(:musicians, :songs, order: "song_id")
      expect(connection.table_options("musicians_songs")[:order]).to eq("song_id")
    end
  end

  describe "column alterations" do
    before do
      connection.create_table("alter_probe", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.string :label
        t.integer :amount, limit: 4
      end
      connection.execute("INSERT INTO alter_probe VALUES (1, 'first', 10)")
    end

    after do
      connection.drop_table("alter_probe", if_exists: true)
    end

    def column(name)
      connection.columns("alter_probe").find { |candidate| candidate.name == name.to_s }
    end

    describe "#rename_column" do
      it "renames keeping the rows" do
        connection.rename_column("alter_probe", :label, :title)
        expect(connection.select_value("SELECT title FROM alter_probe")).to eq("first")
      end

      it "drops the old name" do
        connection.rename_column("alter_probe", :label, :title)
        expect(column(:label)).to be_nil
      end
    end

    describe "#change_column" do
      it "widens the type keeping the rows" do
        connection.change_column("alter_probe", :amount, :integer, limit: 8)
        expect(column(:amount).sql_type).to eq("Int64")
      end

      it "wraps in Nullable when null: true rides along" do
        connection.change_column("alter_probe", :label, :string, null: true)
        expect(column(:label).null).to be(true)
      end

      it "applies a new default in the same statement" do
        connection.change_column("alter_probe", :label, :string, default: "untitled")
        expect(column(:label).default).to eq("untitled")
      end

      it "accepts verbatim ClickHouse types" do
        connection.change_column("alter_probe", :label, "LowCardinality(String)")
        expect(column(:label).sql_type).to eq("LowCardinality(String)")
      end
    end

    describe "#change_column_null" do
      it "makes a column nullable" do
        connection.change_column_null("alter_probe", :label, true)
        expect(column(:label).null).to be(true)
      end

      it "makes a nullable column required again" do
        connection.change_column_null("alter_probe", :label, true)
        connection.change_column_null("alter_probe", :label, false)
        expect(column(:label).null).to be(false)
      end

      it "backfills stored NULLs with the Rails default argument before narrowing" do
        connection.change_column_null("alter_probe", :label, true)
        connection.execute("INSERT INTO alter_probe VALUES (2, NULL, 20)")
        connection.change_column_null("alter_probe", :label, false, "filled")
        expect(connection.select_value("SELECT label FROM alter_probe WHERE id = 2")).to eq("filled")
      end

      it "leaves no placeholder default behind after narrowing" do
        connection.change_column_null("alter_probe", :label, true)
        connection.change_column_null("alter_probe", :label, false)
        expect(column(:label).default).to be_nil
      end

      it "keeps the column's real default through a narrow" do
        connection.change_column("alter_probe", :label, :string, null: true, default: "untitled")
        connection.change_column_null("alter_probe", :label, false)
        expect(column(:label).default).to eq("untitled")
      end

      it "refuses to narrow over stored NULLs without a backfill default" do
        connection.change_column_null("alter_probe", :label, true)
        connection.execute("INSERT INTO alter_probe VALUES (2, NULL, 20)")
        expect { connection.change_column_null("alter_probe", :label, false) }
          .to raise_error(ActiveRecord::ActiveRecordError, /stored NULLs/)
      end
    end

    describe "#change_column_comment" do
      it "attaches the comment to the column" do
        connection.change_column_comment("alter_probe", :label, "human name")
        expect(column(:label).comment).to eq("human name")
      end
    end

    describe "#change_table_comment" do
      it "attaches the comment to the table" do
        connection.change_table_comment("alter_probe", "scratch data")
        expect(connection.table_comment("alter_probe")).to eq("scratch data")
      end
    end

    describe "#add_index / #remove_index" do
      it "adds a data-skipping index to an existing table" do
        connection.add_index("alter_probe", :label, name: "idx_label", using: "bloom_filter", granularity: 2)
        expect(connection.indexes("alter_probe").map(&:name)).to include("idx_label")
      end

      it "records the index type and granularity" do
        connection.add_index("alter_probe", :label, name: "idx_label", using: "bloom_filter", granularity: 2)
        index = connection.indexes("alter_probe").find { |candidate| candidate.name == "idx_label" }
        expect([index.using, index.granularity]).to eq(["bloom_filter", 2])
      end

      it "removes the index by name" do
        connection.add_index("alter_probe", :label, name: "idx_label", using: "bloom_filter")
        connection.remove_index("alter_probe", name: "idx_label")
        expect(connection.indexes("alter_probe").map(&:name)).not_to include("idx_label")
      end
    end
  end
end
