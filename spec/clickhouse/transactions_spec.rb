# frozen_string_literal: true

RSpec.describe "ClickHouse transaction semantics" do
  subject(:model) do
    Class.new(ActiveRecord::Base) do
      self.table_name = "transaction_probe"
      self.primary_key = "id"

      def self.name = "TransactionProbe"
    end
  end

  before(:all) do
    conn = ActiveRecord::Base.lease_connection
    conn.drop_table("transaction_probe", if_exists: true)
    conn.create_table("transaction_probe", order: "id") do |t|
      t.integer :id, limit: 8
      t.string :label, default: ""
    end
  end

  after(:all) do
    ActiveRecord::Base.lease_connection.drop_table("transaction_probe", if_exists: true)
  end

  before { ActiveRecord::Base.lease_connection.execute("TRUNCATE TABLE transaction_probe") }

  it "persists writes made inside a transaction block" do
    model.transaction { model.create!(id: 1, label: "kept") }

    expect(model.count).to eq(1)
  end

  # Rails opens a savepoint for transaction(requires_new: true) nested inside a dirty
  # transaction — e.g. the retry inside create_or_find_by — regardless of
  # supports_savepoints?. ClickHouse has no savepoints, so those verbs must be no-ops
  # like begin/commit/rollback already are.
  it "treats a requires_new transaction nested in a dirty one as a no-op savepoint" do
    model.transaction do
      model.create!(id: 2, label: "outer")
      model.transaction(requires_new: true) { model.create!(id: 3, label: "nested") }
    end

    expect(model.count).to eq(2)
  end

  it "sends no savepoint statements to the server" do
    statements = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
      statements << event.payload[:sql]
    end

    begin
      model.transaction do
        model.create!(id: 4)
        model.transaction(requires_new: true) { model.create!(id: 5) }
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    expect(statements.grep(/SAVEPOINT/i)).to be_empty
  end

  it "cannot undo writes when a nested savepoint rolls back" do
    model.transaction do
      model.create!(id: 6, label: "outer")
      model.transaction(requires_new: true) do
        model.create!(id: 7, label: "not undoable")
        raise ActiveRecord::Rollback
      end
    end

    expect(model.count).to eq(2)
  end
end
