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

  # Rails' time-zone-aware attribute machinery type-checks for the Active Record
  # datetime type (it carries default_timezone awareness the ActiveModel one lacks).
  it "exposes datetime columns as ActiveRecord::Type::DateTime" do
    ts = connection.columns("schema_probe").find { |column| column.name == "ts" }
    expect(ts.fetch_cast_type(connection)).to be_a(ActiveRecord::Type::DateTime)
  end

  it "exposes date columns as ActiveRecord::Type::Date" do
    expect(described_type_for("Date")).to be_a(ActiveRecord::Type::Date)
  end

  def described_type_for(type_string)
    ActiveRecord::ConnectionAdapters::ClickHouse::Types.active_record_cast_type(type_string)
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

  it "maps parenthesized datetime types like Rails' other adapters" do
    expect(connection.type_to_sql("datetime(6)")).to eq("DateTime64(6, 'UTC')")
  end

  it "accepts nanosecond datetime precision (ClickHouse's maximum)" do
    expect(connection.type_to_sql(:datetime, precision: 9)).to eq("DateTime64(9, 'UTC')")
  end

  # Rails injects precision 6 for a bare t.datetime; a nil that survives to the adapter
  # was explicit (precision: nil), meaning the second-precision base type.
  it "maps a precision-less datetime to plain DateTime" do
    expect(connection.type_to_sql(:datetime)).to eq("DateTime('UTC')")
  end

  it "rejects datetime precision past nanoseconds like the server would (code 69)" do
    expect { connection.type_to_sql(:datetime, precision: 10) }
      .to raise_error(ArgumentError, /No timestamp type has precision of 10/)
  end

  it "defaults decimal scale to zero when only precision is given" do
    expect(connection.type_to_sql(:decimal, precision: 2)).to eq("Decimal(2, 0)")
  end

  it "keeps the wide Decimal(38, 10) default when precision is omitted" do
    expect(connection.type_to_sql(:decimal)).to eq("Decimal(38, 10)")
  end

  it "rejects a decimal scale without a precision like Rails' other adapters" do
    expect { connection.type_to_sql(:decimal, scale: 10) }
      .to raise_error(ArgumentError, "Error adding decimal column: precision cannot be empty if scale is specified")
  end

  it "maps binary to String (ClickHouse strings are byte-safe)" do
    expect(connection.type_to_sql(:binary)).to eq("String")
  end

  it "maps blob to String like binary" do
    expect(connection.type_to_sql(:blob)).to eq("String")
  end

  it "supports datetime precision" do
    expect(connection.supports_datetime_with_precision?).to be(true)
  end

  it "gives DSL datetimes Rails' default microsecond precision" do
    connection.create_table("precision_probe", force: true, order: "tuple()") do |t|
      t.datetime :seen_at
    end
    seen_at = connection.columns("precision_probe").find { |c| c.name == "seen_at" }
    expect(seen_at.sql_type).to eq("DateTime64(6, 'UTC')")
  ensure
    connection.drop_table("precision_probe", if_exists: true)
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

    it "no-ops removing a default the column does not have" do
      connection.change_column_default("default_probe", "status", nil)
      expect { connection.change_column_default("default_probe", "status", nil) }.not_to raise_error
    ensure
      connection.change_column_default("default_probe", "status", "old")
    end

    it "round-trips a default containing a newline" do
      connection.change_column_default("default_probe", "status", "foo\nbar")
      expect(connection.columns("default_probe").find { |c| c.name == "status" }.default).to eq("foo\nbar")
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

    it "degrades to an empty sorting key when the reference columns are nullable" do
      connection.create_join_table(:musicians, :songs, column_options: { null: true })
      expect(connection.table_options("musicians_songs")[:order]).to be_nil
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

      it "drops an existing default when the new definition omits one" do
        connection.change_column("alter_probe", :label, :string, default: "untitled")
        connection.change_column("alter_probe", :label, :string)
        expect(column(:label).default).to be_nil
      end

      it "narrows a Nullable column back to non-nullable" do
        connection.change_column("alter_probe", :label, :string, null: true)
        connection.change_column("alter_probe", :label, :string, null: false)
        expect(column(:label).null).to be(false)
      end

      it "leaves no placeholder default behind after narrowing" do
        connection.change_column("alter_probe", :label, :string, null: true)
        connection.change_column("alter_probe", :label, :string, null: false)
        expect(column(:label).default).to be_nil
      end

      it "refuses to narrow over stored NULLs" do
        connection.change_column("alter_probe", :label, :string, null: true)
        connection.execute("INSERT INTO alter_probe (id, label) VALUES (1, NULL)")
        expect { connection.change_column("alter_probe", :label, :string, null: false) }
          .to raise_error(ActiveRecord::ActiveRecordError, /stored NULLs/)
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

      it "rejects non-boolean null arguments like Rails" do
        expect { connection.change_column_null("alter_probe", :label, "false") }
          .to raise_error(ArgumentError, /boolean/)
      end
    end

    describe "#build_change_column_definition" do
      it "describes the change without executing it" do
        definition = connection.build_change_column_definition("alter_probe", :label, :integer, limit: 8)
        expect([definition.column.name.to_s, column(:label).sql_type]).to eq(%w[label String])
      end
    end

    describe "#build_change_column_default_definition" do
      it "describes the default change without executing it" do
        definition = connection.build_change_column_default_definition("alter_probe", :label, "draft")
        expect([definition.default, column(:label).default]).to eq(["draft", nil])
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

      it "defaults the index type to bloom_filter so vanilla Rails migrations port" do
        connection.add_index("alter_probe", :label, name: "idx_label")
        index = connection.indexes("alter_probe").find { |candidate| candidate.name == "idx_label" }
        expect(index.using).to eq("bloom_filter")
      end

      it "reports multi-column indexes as a column-name array" do
        connection.add_index("alter_probe", %i[label amount], name: "idx_pair")
        index = connection.indexes("alter_probe").find { |candidate| candidate.name == "idx_pair" }
        expect(index.columns).to eq(%w[label amount])
      end

      it "renames auto-named indexes with the column, like Rails" do
        connection.add_index("alter_probe", :label)
        connection.rename_column("alter_probe", :label, :title)
        expect(connection.indexes("alter_probe").map(&:name)).to eq(["index_alter_probe_on_title"])
      end

      it "drops dependent skip indexes with the column, like Rails" do
        connection.add_index("alter_probe", :label, name: "idx_label")
        connection.remove_column("alter_probe", :label)
        expect(connection.indexes("alter_probe").map(&:name)).not_to include("idx_label")
      end

      it "builds indexes declared inside create_table without an explicit type" do
        connection.create_table("index_in_create_probe", force: true, order: "tuple()") do |t|
          t.string :sku, index: true
        end
        expect(connection.indexes("index_in_create_probe").map(&:using)).to eq(["bloom_filter"])
      ensure
        connection.drop_table("index_in_create_probe", if_exists: true)
      end

      it "rejects unknown add_index options like Rails" do
        expect { connection.add_index("alter_probe", :label, unqiue: true) }
          .to raise_error(ArgumentError, /unqiue/i)
      end

      it "accepts Rails-portable index options it cannot honor, like length:" do
        connection.add_index("alter_probe", :label, length: 10)
        expect(connection.indexes("alter_probe").map(&:name)).to include("index_alter_probe_on_label")
      end

      it "accepts the internal: flag Rails passes for framework-owned indexes" do
        expect { connection.add_index("alter_probe", :label, internal: true) }.not_to raise_error
      end

      it "rejects index names beyond the identifier limit" do
        expect { connection.add_index("alter_probe", :label, name: "x" * 100) }
          .to raise_error(ArgumentError, /too long/)
      end

      it "no-ops re-adding an existing index with if_not_exists" do
        connection.add_index("alter_probe", :label)
        expect { connection.add_index("alter_probe", :label, if_not_exists: true) }.not_to raise_error
      end

      it "raises ArgumentError removing an index that does not exist" do
        expect { connection.remove_index("alter_probe", :label) }
          .to raise_error(ArgumentError, /No indexes found/)
      end

      it "no-ops removing a missing index with if_exists" do
        expect { connection.remove_index("alter_probe", :label, if_exists: true) }.not_to raise_error
      end

      it "removes an index given its columns through the column: keyword" do
        connection.add_index("alter_probe", %i[label amount])
        connection.remove_index("alter_probe", column: %i[label amount])
        expect(connection.indexes("alter_probe")).to be_empty
      end

      it "resolves an underscore-joined column string to the matching index, like Rails" do
        connection.add_index("alter_probe", %i[label amount])
        connection.remove_index("alter_probe", "label_and_amount")
        expect(connection.indexes("alter_probe")).to be_empty
      end

      it "refuses to remove by a column name that only matches an index's name" do
        connection.add_index("alter_probe", :label, name: "index_alter_probe_on_amount")
        expect { connection.remove_index("alter_probe", "amount") }
          .to raise_error(ArgumentError, /No indexes found/)
      end

      it "renames an index by drop and re-add" do
        connection.add_index("alter_probe", :label, name: "idx_old", granularity: 3)
        connection.rename_index("alter_probe", "idx_old", "idx_new")
        index = connection.indexes("alter_probe").find { |candidate| candidate.name == "idx_new" }
        expect([index.columns, index.granularity]).to eq([["label"], 3])
      end

      it "rejects rename_index targets beyond the identifier limit" do
        connection.add_index("alter_probe", :label, name: "idx_old")
        expect { connection.rename_index("alter_probe", "idx_old", "x" * 100) }
          .to raise_error(ArgumentError, /too long/)
      end
    end

    describe "#rename_table" do
      after do
        connection.drop_table("renamed_probe", if_exists: true)
      end

      it "renames auto-named indexes with the table, like Rails" do
        connection.add_index("alter_probe", :label)
        connection.rename_table("alter_probe", "renamed_probe")
        expect(connection.indexes("renamed_probe").map(&:name)).to eq(["index_renamed_probe_on_label"])
      end
    end
  end
end
