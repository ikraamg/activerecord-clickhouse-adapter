# frozen_string_literal: true

RSpec.describe "ClickHouse error taxonomy" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "raises UnknownTable for exception code 60" do
    expect { connection.select_value("SELECT * FROM definitely_missing_table") }
      .to raise_error(ActiveRecord::ConnectionAdapters::ClickHouse::UnknownTable)
  end

  it "raises UnknownDatabase for exception code 81" do
    expect do
      connection.select_value("SELECT * FROM definitely_missing_database.somewhere")
    end.to raise_error(ActiveRecord::ConnectionAdapters::ClickHouse::UnknownDatabase)
  end

  describe "NULL into a non-nullable column" do
    before(:all) do
      conn = ActiveRecord::Base.lease_connection
      conn.create_table("not_null_probe", force: true, order: "id") do |t|
        t.integer :id, limit: 8
        t.string :label
      end
    end

    after(:all) do
      ActiveRecord::Base.lease_connection.drop_table("not_null_probe", if_exists: true)
    end

    it "raises NotNullViolation instead of coercing to the type default" do
      expect { connection.execute("INSERT INTO not_null_probe VALUES (1, NULL)") }
        .to raise_error(ActiveRecord::NotNullViolation)
    end

    it "writes no row on the failed insert" do
      begin
        connection.execute("INSERT INTO not_null_probe VALUES (1, NULL)")
      rescue ActiveRecord::NotNullViolation
        nil
      end
      expect(connection.select_value("SELECT count() FROM not_null_probe")).to eq(0)
    end
  end
end
