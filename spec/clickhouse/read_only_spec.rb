# frozen_string_literal: true

# ClickHouse enforces read-only server-side through the `readonly` setting:
# 2 = reads only, settings changes allowed; 1 additionally refuses settings
# changes — unusable here because the adapter ships session settings
# (join_use_nulls, ...) as request parameters (probed live: code 164 fires on
# the settings before the SELECT runs). `read_only: true` therefore stamps
# readonly=2 on every request, and code 164 maps to ActiveRecord::ReadOnlyError
# so server-enforced replicas raise the same class Rails' own
# while_preventing_writes uses.
RSpec.describe "Read-only ClickHouse connections" do
  subject(:read_only_adapter) do
    ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(CLICKHOUSE_TEST_CONFIG.merge(read_only: true))
  end

  let(:writer) { ActiveRecord::Base.lease_connection }

  it "answers SELECTs" do
    expect(read_only_adapter.select_value("SELECT 1")).to eq(1)
  end

  it "refuses DDL with ActiveRecord::ReadOnlyError" do
    expect { read_only_adapter.execute("CREATE TABLE read_only_probe (id Int64) ENGINE = MergeTree ORDER BY id") }
      .to raise_error(ActiveRecord::ReadOnlyError)
  end

  describe "writes against an existing table" do
    before do
      writer.create_table("read_only_rows", force: true, order: "id") do |t|
        t.integer :id, limit: 8
      end
    end

    after { writer.drop_table("read_only_rows", if_exists: true) }

    it "refuses INSERTs with ActiveRecord::ReadOnlyError" do
      expect { read_only_adapter.execute("INSERT INTO read_only_rows (id) VALUES (1)") }
        .to raise_error(ActiveRecord::ReadOnlyError)
    end
  end

  describe "a server-enforced readonly user" do
    subject(:replica_adapter) do
      ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(
        CLICKHOUSE_TEST_CONFIG.merge(username: "ar_readonly_spec", password: "readonly")
      )
    end

    before do
      writer.execute(<<~SQL)
        CREATE USER IF NOT EXISTS ar_readonly_spec
        IDENTIFIED WITH plaintext_password BY 'readonly'
        SETTINGS readonly = 2
      SQL
      writer.execute("GRANT SELECT ON #{CLICKHOUSE_TEST_CONFIG[:database]}.* TO ar_readonly_spec")
    end

    after { writer.execute("DROP USER IF EXISTS ar_readonly_spec") }

    it "reads through the adapter untouched" do
      expect(replica_adapter.select_value("SELECT 41 + 1")).to eq(42)
    end

    it "surfaces its write refusal as ActiveRecord::ReadOnlyError" do
      expect { replica_adapter.execute("CREATE TABLE replica_probe (id Int64) ENGINE = MergeTree ORDER BY id") }
        .to raise_error(ActiveRecord::ReadOnlyError)
    end
  end

  describe "a user without grants" do
    subject(:grantless_adapter) do
      ActiveRecord::ConnectionAdapters::ClickHouseAdapter.new(
        CLICKHOUSE_TEST_CONFIG.merge(username: "ar_grantless_spec", password: "grantless")
      )
    end

    before do
      writer.execute("CREATE USER IF NOT EXISTS ar_grantless_spec IDENTIFIED WITH plaintext_password BY 'grantless'")
      writer.create_table("granted_rows", force: true, order: "id") do |t|
        t.integer :id, limit: 8
      end
    end

    after do
      writer.execute("DROP USER IF EXISTS ar_grantless_spec")
      writer.drop_table("granted_rows", if_exists: true)
    end

    it "raises AccessDenied for exception code 497" do
      expect { grantless_adapter.select_value("SELECT count() FROM granted_rows") }
        .to raise_error(ActiveRecord::ConnectionAdapters::ClickHouse::AccessDenied)
    end
  end
end
