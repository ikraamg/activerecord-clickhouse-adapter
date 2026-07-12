# frozen_string_literal: true

RSpec.describe "ClickHouse relation coverage" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "relation_probe"

      def self.name = "RelationProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("relation_probe", if_exists: true)
    conn.create_table("relation_probe", order: "(device_id, ts)") do |t|
      t.integer :device_id, limit: 8
      t.datetime :ts, precision: 3
      t.string :kind, low_cardinality: true, default: ""
      t.decimal :amount, precision: 18, scale: 4, default: 0
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("relation_probe", if_exists: true)
  end

  before do
    ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE relation_probe")
    model.insert_all!([
                        { device_id: 1, ts: Time.utc(2026, 7, 1, 8), kind: "render", amount: "10.5" },
                        { device_id: 1, ts: Time.utc(2026, 7, 1, 9), kind: "serve", amount: "0.25" },
                        { device_id: 2, ts: Time.utc(2026, 7, 1, 10), kind: "render", amount: "7.75" }
                      ])
  end

  it "answers exists?" do
    expect(model.where(kind: "serve").exists?).to be(true)
  end

  it "answers exists? negatively" do
    expect(model.where(kind: "checkin").exists?).to be(false)
  end

  it "finds by attributes" do
    expect(model.find_by(device_id: 2).kind).to eq("render")
  end

  it "supports distinct" do
    expect(model.distinct.pluck(:kind).sort).to eq(%w[render serve])
  end

  it "supports or-chains" do
    relation = model.where(kind: "serve").or(model.where(device_id: 2))
    expect(relation.count).to eq(2)
  end

  it "supports not" do
    expect(model.where.not(kind: "render").count).to eq(1)
  end

  it "supports limit and offset" do
    expect(model.order(:ts).limit(1).offset(1).pluck(:kind)).to eq(["serve"])
  end

  it "plucks multiple columns" do
    expect(model.order(:ts).limit(1).pluck(:device_id, :kind)).to eq([[1, "render"]])
  end

  it "sums Decimal columns exactly" do
    expect(model.sum(:amount)).to eq(BigDecimal("18.5"))
  end

  it "computes minimum and maximum" do
    expect([model.minimum(:amount), model.maximum(:amount)]).to eq([BigDecimal("0.25"), BigDecimal("10.5")])
  end

  it "iterates in batches over an explicit cursor (no id column)" do
    seen = []
    model.find_each(cursor: %i[device_id ts], batch_size: 2) { |record| seen << record.kind }
    expect(seen.length).to eq(3)
  end
end
