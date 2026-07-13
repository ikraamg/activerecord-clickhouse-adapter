# frozen_string_literal: true

RSpec.describe "ClickHouse quoting" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  it "escapes single quotes in strings" do
    expect(connection.quote("O'Brien")).to eq("'O\\'Brien'")
  end

  it "escapes backslashes in strings" do
    expect(connection.quote("a\\b")).to eq("'a\\\\b'")
  end

  it "quotes identifiers with backticks" do
    expect(connection.quote_column_name("order")).to eq("`order`")
  end

  it "quotes nil as NULL" do
    expect(connection.quote(nil)).to eq("NULL")
  end

  it "quotes booleans as ClickHouse literals" do
    expect(connection.quote(true)).to eq("true")
    expect(connection.quote(false)).to eq("false")
  end

  it "quotes arrays as ClickHouse array literals" do
    expect(connection.quote([1, "a"])).to eq("[1, 'a']")
  end

  it "quotes hashes as ClickHouse map literals" do
    expect(connection.quote("k" => 1)).to eq("{'k': 1}")
  end

  # DateTime64 stores an epoch and the server parses naive strings in its own timezone
  # (UTC here), so UTC is the only faithful wire encoding — under default_timezone
  # :local the abstract quoted_date would emit local wall-clock and shift the instant.
  describe "quoted_date under default_timezone :local" do
    around do |example|
      original = ActiveRecord.default_timezone
      ActiveRecord.default_timezone = :local
      example.run
    ensure
      ActiveRecord.default_timezone = original
    end

    it "still encodes the UTC wall-clock" do
      moment = Time.utc(2003, 7, 16, 14, 28, 11).getlocal("+04:00")
      expect(connection.quoted_date(moment)).to eq("2003-07-16 14:28:11")
    end

    it "keeps fractional seconds" do
      moment = Time.utc(2003, 7, 16, 14, 28, 11, 223_300).getlocal("+04:00")
      expect(connection.quoted_date(moment)).to eq("2003-07-16 14:28:11.223300")
    end
  end

  # disallow_raw_sql! vets order/pluck arguments against these matchers; the abstract
  # ones only admit bare or dot-qualified words, so backtick-quoted names — this
  # adapter's own quote_column_name output — would raise UnknownAttributeReference.
  describe "identifier matchers admit backtick-quoted names" do
    subject(:adapter_class) { ActiveRecord::ConnectionAdapters::ClickHouseAdapter }

    it "accepts a backtick-quoted qualified column" do
      expect(adapter_class.column_name_matcher).to match("`comments`.`id`")
    end

    it "accepts a backtick-quoted column with direction" do
      expect(adapter_class.column_name_with_order_matcher).to match("`comments`.`id` DESC")
    end

    it "still rejects raw SQL smuggled alongside a column" do
      expect(adapter_class.column_name_with_order_matcher).not_to match("id; DROP TABLE users")
    end
  end

  it "round-trips a quoted injection payload via SELECT" do
    sql = "SELECT #{connection.quote("'; DROP TABLE users; --")}"
    expect(connection.select_value(sql)).to eq("'; DROP TABLE users; --")
  end

  it "round-trips unicode through quoting" do
    expect(connection.select_value("SELECT #{connection.quote("héllo 👋")}")).to eq("héllo 👋")
  end
end
