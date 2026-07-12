# frozen_string_literal: true

# Decision (2026-07-12 review): records loaded from models that declare an explicit
# `self.primary_key` support update/delete/destroy — the pattern for ReplacingMergeTree
# tables whose ORDER BY key is unique by design. Models without one stay read-mostly
# (update_all/delete_all with explicit WHERE are the API).
RSpec.describe "ClickHouse record mutations via explicit primary key" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "pk_probe"
      self.primary_key = "slug"

      def self.name = "PkProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("pk_probe", if_exists: true)
    conn.create_table("pk_probe", engine: "ReplacingMergeTree(revised_at)", order: "slug") do |t|
      t.string :slug
      t.string :title, default: ""
      t.datetime :revised_at, precision: 6, default: -> { "now64(6)" }
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("pk_probe", if_exists: true)
  end

  before do
    ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE pk_probe")
    model.create!(slug: "alpha", title: "first")
    model.create!(slug: "beta", title: "second")
  end

  it "finds records by primary key" do
    expect(model.find("alpha").title).to eq("first")
  end

  it "updates a loaded record through a mutation" do
    record = model.find("alpha")
    record.update!(title: "revised")
    expect(model.find("alpha").title).to eq("revised")
  end

  it "leaves other rows untouched by a record update" do
    model.find("alpha").update!(title: "revised")
    expect(model.find("beta").title).to eq("second")
  end

  it "deletes a loaded record" do
    model.find("alpha").destroy!
    expect(model.pluck(:slug)).to eq(["beta"])
  end
end
