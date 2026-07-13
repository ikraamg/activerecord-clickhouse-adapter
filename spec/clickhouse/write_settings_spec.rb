# frozen_string_literal: true

# .settings() on a relation already rides SELECTs as a SQL SETTINGS clause; for writes
# (insert_all/update_all/delete_all) the same relation state travels as per-request HTTP
# query parameters, since ALTER/INSERT grammars each place SETTINGS differently.
RSpec.describe "ClickHouse per-write settings" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      include ActiveRecord::ConnectionAdapters::ClickHouse::Querying

      self.table_name = "write_settings_probe"

      def self.name = "WriteSettingsProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("write_settings_probe", if_exists: true)
    conn.create_table("write_settings_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :status, default: ""
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("write_settings_probe", if_exists: true)
  end

  before { ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE write_settings_probe") }

  it "applies settings to insert_all (readonly proves the wire passthrough)" do
    expect { model.settings(readonly: 1).insert_all!([{ id: 1 }]) }
      .to raise_error(ActiveRecord::StatementInvalid, /readonly/i)
  end

  it "applies settings to update_all" do
    model.insert_all!([{ id: 1, status: "new" }])
    expect { model.settings(readonly: 1).where(id: 1).update_all(status: "done") }
      .to raise_error(ActiveRecord::StatementInvalid, /readonly/i)
  end

  it "applies settings to delete_all" do
    model.insert_all!([{ id: 1 }])
    expect { model.settings(readonly: 1).delete_all }
      .to raise_error(ActiveRecord::StatementInvalid, /readonly/i)
  end

  it "inserts asynchronously but durably with async_insert settings" do
    model.settings(async_insert: 1, wait_for_async_insert: 1).insert_all!([{ id: 7 }])
    expect(model.where(id: 7).count).to eq(1)
  end

  it "leaves the connection's settings untouched afterwards" do
    model.settings(async_insert: 1).insert_all!([{ id: 8 }])
    expect(ActiveRecord::Base.lease_connection.select_value("SELECT getSetting('async_insert')")).to be(false)
  end

  it "rejects unsafe setting names before they reach the wire" do
    expect { model.settings("bad name" => 1).insert_all!([{ id: 9 }]) }
      .to raise_error(ArgumentError, /setting name/)
  end
end
