# frozen_string_literal: true

RSpec.describe "ClickHouse CRUD semantics" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "crud_probe"
      # Ordered/limited mutations compile to WHERE pk IN (subquery), which needs a key.
      self.primary_key = "device_id"

      def self.name = "CrudProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("crud_probe", if_exists: true)
    conn.create_table("crud_probe", order: "device_id") do |t|
      t.integer :device_id, limit: 8
      t.string :status, default: ""
      t.integer :duration_ms, null: true
      t.datetime :created_at, precision: 6, null: true
      t.datetime :updated_at, precision: 6, null: true
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("crud_probe", if_exists: true)
  end

  before do
    ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE crud_probe")
  end

  describe "bulk insert" do
    # insert_all implies skip-duplicates; without unique constraints nothing can
    # conflict, so the semantics hold vacuously and the INSERT goes through plain
    # (decided porting TRMNL core, whose telemetry sink writes with insert_all).
    it "treats insert_all's duplicate-skip as vacuously satisfied" do
      model.insert_all([{ device_id: 1 }, { device_id: 1 }])
      expect(model.count).to eq(2)
    end

    it "inserts all rows in one statement" do
      model.insert_all!([
                          { device_id: 1, status: "ok" },
                          { device_id: 2, status: "ok" },
                          { device_id: 3, status: "err" }
                        ])
      expect(model.count).to eq(3)
    end

    it "round-trips values through bulk insert" do
      model.insert_all!([{ device_id: 9, status: "it's odd", duration_ms: 5 }])
      expect(model.where(device_id: 9).take.status).to eq("it's odd")
    end

    it "raises honestly for upsert (no ClickHouse conflict semantics)" do
      expect { model.upsert_all([{ device_id: 1 }], unique_by: :device_id) }
        .to raise_error(ArgumentError, /does not support/)
    end

    # Rails stamps record_timestamps rows with connection.high_precision_current_timestamp;
    # the default CURRENT_TIMESTAMP literal is not a ClickHouse identifier.
    it "stamps timestamp columns via record_timestamps" do
      timestamped = model.tap { |klass| klass.record_timestamps = true }
      timestamped.insert_all!([{ device_id: 12, status: "ok" }], record_timestamps: true)
      expect(timestamped.where(device_id: 12).take.created_at).to be_within(60).of(Time.now.utc)
    end
  end

  describe "delete_all" do
    before do
      model.insert_all!([{ device_id: 1 }, { device_id: 2 }, { device_id: 3 }])
    end

    it "deletes matching rows with a lightweight DELETE" do
      model.where(device_id: 2).delete_all
      expect(model.pluck(:device_id).sort).to eq([1, 3])
    end

    it "deletes every row when unscoped" do
      model.delete_all
      expect(model.count).to eq(0)
    end

    # The server reports no affected-row count for mutations (X-ClickHouse-Summary is
    # all zeros — probed 2026-07-13), so the adapter counts matching rows first.
    it "returns the number of deleted rows" do
      expect(model.where(device_id: [1, 2]).delete_all).to eq(2)
    end

    it "returns the full count for an unscoped delete" do
      expect(model.delete_all).to eq(3)
    end

    # Association scopes routinely carry an order (`has_many ..., -> { order "id" }`);
    # the visitor rewrites the mutation into WHERE key IN (subquery), and the count
    # must survive that rewrite instead of reporting zero.
    it "returns the number of deleted rows for an ordered relation" do
      expect(model.where(device_id: [1, 2]).order(:device_id).delete_all).to eq(2)
    end

    it "returns the capped count for a limited delete" do
      expect(model.order(:device_id).limit(2).delete_all).to eq(2)
    end

    it "deletes only the limited slice" do
      model.order(:device_id).limit(2).delete_all
      expect(model.pluck(:device_id)).to eq([3])
    end

    # A joined delete_all compiles to WHERE pk IN (SELECT ... INNER JOIN ... ON a.x = b.y);
    # bare-name rewriting must stop at the subquery boundary or the ON clause turns
    # ambiguous (AMBIGUOUS_COLUMN_NAME, code 352).
    it "keeps qualified column names inside the subquery of a joined delete" do
      conn = ActiveRecord::Base.lease_connection
      conn.drop_table("crud_probe_events", if_exists: true)
      conn.create_table("crud_probe_events", order: "device_id") do |t|
        t.integer :device_id, limit: 8
      end
      conn.execute("INSERT INTO crud_probe_events VALUES (2)")

      model.has_many :crud_probe_events, foreign_key: :device_id, primary_key: :device_id,
                                         class_name: "CrudProbeEvent"
      stub_const("CrudProbeEvent", Class.new(ActiveRecord::Base) { self.table_name = "crud_probe_events" })

      expect(model.joins(:crud_probe_events).delete_all).to eq(1)
    ensure
      ActiveRecord::Base.lease_connection.drop_table("crud_probe_events", if_exists: true)
    end

    # Ported from ../clickhouse/tests/queries/0_stateless/02319_lightweight_delete_on_merge_tree.sql
    it "deletes across a 100-row part by equality then IN-list, matching the upstream oracle" do
      model.delete_all
      model.insert_all!(Array.new(100) { |n| { device_id: n, status: n.to_s } })
      model.where(device_id: 10).delete_all
      model.where(status: %w[1 2 3 4]).delete_all
      expect(model.count).to eq(95)
    end
  end

  describe "update_all" do
    before do
      model.insert_all!([{ device_id: 1, status: "new" }, { device_id: 2, status: "new" }])
    end

    it "mutates matching rows via ALTER TABLE UPDATE" do
      model.where(device_id: 1).update_all(status: "done")
      expect(model.where(device_id: 1).take.status).to eq("done")
    end

    it "leaves non-matching rows untouched" do
      model.where(device_id: 1).update_all(status: "done")
      expect(model.where(device_id: 2).take.status).to eq("new")
    end

    it "mutates every row when unscoped" do
      model.update_all(status: "swept")
      expect(model.distinct.pluck(:status)).to eq(["swept"])
    end

    it "returns the number of matching rows" do
      expect(model.where(device_id: 1).update_all(status: "done")).to eq(1)
    end

    it "returns the full count for an unscoped update" do
      expect(model.update_all(status: "swept")).to eq(2)
    end

    it "returns the number of matching rows for an ordered relation" do
      expect(model.order(:device_id).update_all(status: "swept")).to eq(2)
    end
  end
end
