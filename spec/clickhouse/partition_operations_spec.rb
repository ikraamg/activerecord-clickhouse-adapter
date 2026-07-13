# frozen_string_literal: true

# Partition lifecycle — the OLAP replacement for bulk deletes and archival: detach
# takes a partition offline (reversibly), attach brings it back, drop removes it
# instantly (no mutation), freeze hard-links a local backup.
RSpec.describe "ClickHouse partition operations" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before do
    connection.drop_table("partition_probe", if_exists: true)
    connection.create_table("partition_probe", partition: "toYYYYMM(day)", order: "day") do |t|
      t.date :day
      t.integer :value, limit: 8
    end
    connection.execute("INSERT INTO partition_probe VALUES ('2026-06-15', 1), ('2026-07-13', 2)")
  end

  after { connection.drop_table("partition_probe", if_exists: true) }

  def partition_row_count
    connection.select_value("SELECT count() FROM partition_probe").to_i
  end

  describe "#partitions" do
    it "lists active partitions" do
      expect(connection.partitions("partition_probe")).to eq(%w[202606 202607])
    end
  end

  describe "#detach_partition" do
    it "takes the partition's rows offline" do
      connection.detach_partition("partition_probe", "202606")
      expect(partition_row_count).to eq(1)
    end
  end

  describe "#attach_partition" do
    it "brings detached rows back" do
      connection.detach_partition("partition_probe", "202606")
      connection.attach_partition("partition_probe", "202606")
      expect(partition_row_count).to eq(2)
    end
  end

  describe "#drop_partition" do
    it "removes the partition's rows without a mutation" do
      connection.drop_partition("partition_probe", "202606")
      expect(partition_row_count).to eq(1)
    end
  end

  describe "#freeze_partition" do
    it "accepts a backup name" do
      expect { connection.freeze_partition("partition_probe", "202607", name: "spec_backup") }
        .not_to raise_error
    end
  end

  describe "quoting" do
    it "rejects partition expressions that could smuggle SQL" do
      expect { connection.drop_partition("partition_probe", "202606; DROP TABLE x") }
        .to raise_error(ActiveRecord::StatementInvalid)
    end
  end
end
