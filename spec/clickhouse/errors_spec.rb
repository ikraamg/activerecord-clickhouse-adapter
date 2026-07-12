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
end
