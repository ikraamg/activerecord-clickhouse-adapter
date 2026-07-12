# frozen_string_literal: true

RSpec.describe "ClickHouse CRUD semantics" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "crud_probe"

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
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("crud_probe", if_exists: true)
  end

  before do
    ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE crud_probe")
  end

  describe "bulk insert" do
    it "raises honestly for insert_all (no duplicate-skip semantics in ClickHouse)" do
      expect { model.insert_all([{ device_id: 1 }]) }
        .to raise_error(ArgumentError, /does not support skipping duplicates/)
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
  end
end
