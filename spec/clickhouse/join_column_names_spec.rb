# frozen_string_literal: true

# With two or more JOINs, ClickHouse's analyzer renames the colliding columns of a
# qualified star (`SELECT comments.*`) to `comments.id`, `comments.post_id`, … on the
# wire (probed 2026-07-13; no setting restores bare names). Rails maps attributes by
# bare column name, so every multi-join `t.*` read would raise MissingAttributeError.
RSpec.describe "ClickHouse join result column names" do
  subject(:connection) { ActiveRecord::Base.lease_connection }

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    %w[join_names_left join_names_right].each { |table| conn.drop_table(table, if_exists: true) }
    conn.create_table("join_names_left", order: "id") do |t|
      t.integer :id, limit: 8
      t.integer :right_id, limit: 8
      t.string :label
    end
    conn.create_table("join_names_right", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label
    end
    conn.execute("INSERT INTO join_names_left VALUES (1, 10, 'left')")
    conn.execute("INSERT INTO join_names_right VALUES (10, 'right')")
  end

  after(:all) do
    conn = ActiveRecord::Base.lease_connection
    %w[join_names_left join_names_right].each { |table| conn.drop_table(table, if_exists: true) }
  end

  let(:multi_join_star_sql) do
    <<~SQL.squish
      SELECT join_names_left.* FROM join_names_left
      INNER JOIN join_names_right ON join_names_right.id = join_names_left.right_id
      INNER JOIN join_names_right AS again ON again.id = join_names_left.right_id
    SQL
  end

  it "returns bare column names for a qualified star across multiple joins" do
    expect(connection.select_all(multi_join_star_sql).columns).to eq(%w[id right_id label])
  end

  it "keeps values aligned with the renamed columns" do
    expect(connection.select_all(multi_join_star_sql).first).to eq(
      "id" => 1, "right_id" => 10, "label" => "left"
    )
  end

  # The server itself leaves the first duplicate bare and qualifies the rest, so
  # stripping the qualifier here would collide with the existing bare name.
  it "keeps qualified names when stripping them would collide" do
    sql = <<~SQL.squish
      SELECT join_names_left.label, join_names_right.label FROM join_names_left
      INNER JOIN join_names_right ON join_names_right.id = join_names_left.right_id
    SQL

    expect(connection.select_all(sql).columns).to eq(%w[label join_names_right.label])
  end
end
