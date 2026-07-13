# frozen_string_literal: true

# Rails' QueryLogs (sqlcommenter format) appends /*tags*/ after the statement, but
# ClickHouse parses everything after VALUES with ValuesBlockInputFormat, which rejects
# trailing comments (CANNOT_PARSE_INPUT_ASSERTION_FAILED — probed live 2026-07-13 while
# porting TRMNL core). The adapter hoists a trailing comment to the front of INSERTs.
RSpec.describe "query log comments" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before do
    connection.create_table(:comment_probes, id: false, order: "value", force: true) do |t|
      t.integer :value, null: false
      t.string :label, default: ""
    end
  end

  after { connection.drop_table(:comment_probes, if_exists: true) }

  it "accepts an INSERT ... VALUES with a trailing sqlcommenter comment" do
    connection.execute("INSERT INTO comment_probes (value) VALUES (1) /*application='Trmnl'*/")
    expect(connection.select_value("SELECT value FROM comment_probes")).to eq(1)
  end

  it "accepts multiple trailing comments" do
    connection.execute("INSERT INTO comment_probes (value) VALUES (2) /*app='a'*/ /*controller='b'*/")
    expect(connection.select_value("SELECT value FROM comment_probes")).to eq(2)
  end

  it "leaves a VALUES string literal that merely contains comment markers alone" do
    connection.execute("INSERT INTO comment_probes (value, label) VALUES (3, 'text /* not a comment */ end')")
    expect(connection.select_value("SELECT label FROM comment_probes")).to eq("text /* not a comment */ end")
  end

  it "keeps trailing comments on SELECT statements untouched" do
    connection.execute("INSERT INTO comment_probes (value) VALUES (4)")
    expect(connection.select_value("SELECT value FROM comment_probes /*application='Trmnl'*/")).to eq(4)
  end
end
