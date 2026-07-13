# frozen_string_literal: true

# DateTime64 stores an epoch, so the instant is zone-free; representation is not.
# Under ActiveRecord.default_timezone = :local every built-in adapter hands back
# local-zoned Time instances — Rails' own BasicsTest asserts the month/day/zone of
# the result (test_preserving_time_objects_*_to_default_timezone_local).
RSpec.describe "DateTime reads under default_timezone :local" do
  subject(:adapter) { ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(CLICKHOUSE_TEST_CONFIG) }

  around do |example|
    previous = ActiveRecord.default_timezone
    ActiveRecord.default_timezone = :local
    example.run
  ensure
    ActiveRecord.default_timezone = previous
  end

  after { adapter.disconnect! }

  it "preserves the DateTime64 instant" do
    value = adapter.select_value("SELECT toDateTime64('2000-01-01 00:00:00', 3, 'UTC')")
    expect(value).to eq(Time.utc(2000, 1, 1))
  end

  it "represents DateTime64 in the local zone" do
    value = adapter.select_value("SELECT toDateTime64('2000-01-01 00:00:00', 3, 'UTC')")
    expect(value.utc?).to be(false)
  end

  it "represents plain DateTime in the local zone" do
    value = adapter.select_value("SELECT toDateTime('2000-01-01 00:00:00', 'UTC')")
    expect(value.utc?).to be(false)
  end

  context "when reading over the JSON wire" do
    subject(:adapter) do
      ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(CLICKHOUSE_TEST_CONFIG.merge(select_format: :json))
    end

    it "preserves the DateTime64 instant" do
      value = adapter.select_value("SELECT toDateTime64('2000-01-01 00:00:00', 3, 'UTC')")
      expect(value).to eq(Time.utc(2000, 1, 1))
    end

    it "represents DateTime64 in the local zone" do
      value = adapter.select_value("SELECT toDateTime64('2000-01-01 00:00:00', 3, 'UTC')")
      expect(value.utc?).to be(false)
    end
  end
end
