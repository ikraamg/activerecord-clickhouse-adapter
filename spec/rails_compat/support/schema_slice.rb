# frozen_string_literal: true

# Translated slice of activerecord/test/schema/schema.rb (v8.1.3) covering the tables
# the vendored suites touch. Translation rules (PLAN.md §5 #14, #15):
#   - implicit-id tables get an explicit Int64 id and a synthesized `order: "id"`
#     (fixtures generate client-side ids, so the id column is always populated);
#   - columns are Nullable by default, matching Rails schema semantics — aggregate
#     tests depend on missing fixture values being NULL, not ClickHouse zero-defaults;
#   - upstream index definitions are dropped (unique/partial indexes don't exist here);
#   - upstream `primary_key:` options become model-level primary keys via PRIMARY_KEYS.
module ARCompat
  module SchemaSlice
    # Tables whose upstream schema declares an explicit primary_key option.
    PRIMARY_KEYS = {
      "cpk_books" => %i[author_id id],
      "cpk_chapters" => %i[author_id id]
    }.freeze

    # Tables the harness must reset between tests beyond the fixture tables, which
    # reload every test anyway (decision #15: truncation, no transactions to roll back).
    TABLES = %w[
      1_need_quoting accounts audit_logs author_addresses authors books carts clubs
      comments companies contracts cpk_books cpk_chapters developers edges having
      minivans numeric_data organizations posts ratings ship_parts ships speedometers
      subscribers subscriptions topics
      toooooooooooooooooooooooooooooooooo_long_table_names treasures
    ].freeze

    module_function

    def load(connection)
      connection.create_table :"1_need_quoting", force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :accounts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :firm_id, limit: 8, null: true
        t.string :firm_name, null: true
        t.integer :credit_limit, null: true
        t.string :status, null: true
        t.integer "a" * 64, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :audit_logs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :message
        t.integer :developer_id, limit: 8
        t.integer :unvalidated_developer_id, limit: 8, null: true
      end

      connection.create_table :author_addresses, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :authors, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
        t.integer :author_address_id, limit: 8, null: true
        t.integer :author_address_extra_id, limit: 8, null: true
        t.string :organization_id, null: true
        t.string :owned_essay_id, null: true
        t.integer :published_author_id, limit: 8, null: true
      end

      connection.create_table :books, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :author_id, limit: 8, null: true
        t.string :format, null: true
        t.integer :format_record_id, limit: 8, null: true
        t.string :format_record_type, null: true
        t.string :name, null: true
        t.integer :status, null: true, default: 0
        t.integer :last_read, null: true, default: 0
        t.integer :nullable_status, null: true
        t.integer :language, null: true, default: 0
        t.integer :author_visibility, null: true, default: 0
        t.integer :illustrator_visibility, null: true, default: 0
        t.integer :font_size, null: true, default: 0
        t.integer :difficulty, null: true, default: 0
        t.float :rating, null: true
        t.string :cover, null: true, default: "hard"
        t.string :symbol_status, null: true, default: "proposed"
        t.string :isbn, null: true
        t.string :external_id, null: true
        t.string :original_name, null: true
        t.datetime :published_on, precision: 6, null: true
        t.boolean :boolean_status, null: true
        t.integer :tags_count, null: true, default: 0
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
        t.date :updated_on, null: true
      end

      # shop_id joins the sorting key, so it stays non-nullable (allow_nullable_key is off).
      connection.create_table :carts, force: true, order: "(shop_id, id)" do |t|
        t.integer :id, limit: 8
        t.integer :shop_id, limit: 8
        t.string :title, null: true
      end

      connection.create_table :clubs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :category_id, limit: 8, null: true
      end

      connection.create_table :comments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :post_id, limit: 8
        t.string :body
        t.string :type, null: true
        t.integer :label, null: true, default: 0
        t.integer :tags_count, null: true, default: 0
        t.integer :children_count, null: true, default: 0
        t.integer :parent_id, limit: 8, null: true
        t.integer :author_id, limit: 8, null: true
        t.string :author_type, null: true
        t.string :resource_id, null: true
        t.string :resource_type, null: true
        t.integer :origin_id, limit: 8, null: true
        t.string :origin_type, null: true
        t.integer :developer_id, limit: 8, null: true
        t.datetime :updated_at, precision: 6, null: true
        t.datetime :deleted_at, precision: 6, null: true
        t.integer :comments, null: true
        t.integer :company, null: true
      end

      connection.create_table :companies, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :type, null: true
        t.integer :firm_id, limit: 8, null: true
        t.string :firm_name, null: true
        t.string :name, null: true
        t.integer :client_of, limit: 8, null: true
        t.integer :rating, limit: 8, null: true, default: 1
        t.integer :account_id, limit: 8, null: true
        t.string :description, null: true, default: ""
        t.integer :status, null: true, default: 0
      end

      connection.create_table :contracts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :developer_id, limit: 8, null: true
        t.integer :company_id, limit: 8, null: true
        t.string :metadata, null: true
        t.integer :count, null: true
      end

      connection.create_table :cpk_books, force: true, order: "(author_id, id)" do |t|
        t.integer :author_id, limit: 8
        t.integer :id, limit: 8
        t.string :title, null: true
        t.integer :revision, null: true
        t.integer :order_id, limit: 8, null: true
        t.integer :shop_id, limit: 8, null: true
      end

      connection.create_table :cpk_chapters, force: true, order: "(author_id, id)" do |t|
        t.integer :author_id, limit: 8
        t.integer :id, limit: 8
        t.integer :book_id, limit: 8, null: true
        t.string :title, null: true
      end

      connection.create_table :developers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.string :first_name, null: true
        t.integer :salary, null: true, default: 70_000
        t.integer :firm_id, limit: 8, null: true
        t.integer :mentor_id, limit: 8, null: true
        t.datetime :legacy_created_at, precision: 6, null: true
        t.datetime :legacy_updated_at, precision: 6, null: true
        t.datetime :legacy_created_on, precision: 6, null: true
        t.datetime :legacy_updated_on, precision: 6, null: true
      end

      connection.create_table :edges, force: true, order: "(source_id, sink_id)" do |t|
        t.integer :source_id, limit: 8
        t.integer :sink_id, limit: 8
      end

      connection.create_table :having, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :where, null: true
      end

      connection.create_table :minivans, force: true, order: "minivan_id" do |t|
        t.string :minivan_id
        t.string :name, null: true
        t.string :speedometer_id, null: true
        t.string :color, null: true
      end

      connection.create_table :numeric_data, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.decimal :bank_balance, precision: 10, scale: 2, null: true
        t.decimal :big_bank_balance, precision: 15, scale: 2, null: true
        t.decimal :unscaled_bank_balance, precision: 10, scale: 0, null: true
        t.decimal :world_population, precision: 20, scale: 0, null: true
        t.decimal :my_house_population, precision: 2, scale: 0, null: true
        t.decimal :decimal_number, null: true
        t.decimal :decimal_number_with_default, precision: 3, scale: 2, null: true, default: 2.78
        t.decimal :numeric_number, null: true
        t.float :temperature, null: true
        t.float :temperature_with_limit, null: true
        t.decimal :decimal_number_big_precision, precision: 20, scale: 0, null: true
        t.decimal :atoms_in_universe, precision: 55, scale: 0, null: true
      end

      connection.create_table :organizations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :posts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :author_id, limit: 8, null: true
        t.string :title
        t.string :body
        t.string :type, null: true
        t.integer :legacy_comments_count, null: true, default: 0
        t.integer :taggings_with_delete_all_count, null: true, default: 0
        t.integer :taggings_with_destroy_count, null: true, default: 0
        t.integer :tags_count, null: true, default: 0
        t.integer :indestructible_tags_count, null: true, default: 0
        t.integer :tags_with_destroy_count, null: true, default: 0
        t.integer :tags_with_nullify_count, null: true, default: 0
      end

      connection.create_table :ratings, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :comment_id, limit: 8, null: true
        t.integer :value, null: true
      end

      connection.create_table :ship_parts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :ship_id, limit: 8, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :ships, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :pirate_id, limit: 8, null: true
        t.integer :developer_id, limit: 8, null: true
        t.integer :update_only_pirate_id, limit: 8, null: true
        t.integer :treasures_count, null: true, default: 0
        t.datetime :created_at, precision: 6, null: true
        t.datetime :created_on, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
        t.datetime :updated_on, precision: 6, null: true
      end

      connection.create_table :speedometers, force: true, order: "speedometer_id" do |t|
        t.string :speedometer_id
        t.string :name, null: true
        t.string :dashboard_id, null: true
      end

      connection.create_table :subscribers, force: true, order: "nick" do |t|
        t.string :nick
        t.string :name, null: true
        t.integer :id, limit: 8, null: true
        t.integer :books_count, default: 0
        t.integer :update_count, default: 0
      end

      connection.create_table :subscriptions, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :subscriber_id, null: true
        t.integer :book_id, limit: 8, null: true
      end

      connection.create_table :topics, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :title, null: true
        t.string :author_name, null: true
        t.string :author_email_address, null: true
        t.datetime :written_on, precision: 6, null: true
        t.column :bonus_time, "Nullable(DateTime64(6, 'UTC'))"
        t.date :last_read, null: true
        t.string :content, null: true
        t.string :important, null: true
        t.string :binary_content, null: true
        t.boolean :approved, null: true, default: true
        t.integer :replies_count, null: true, default: 0
        t.integer :unique_replies_count, null: true, default: 0
        t.integer :parent_id, limit: 8, null: true
        t.string :parent_title, null: true
        t.string :type, null: true
        t.string :group, null: true
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :toooooooooooooooooooooooooooooooooo_long_table_names, force: true,
                                                                                     order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :toooooooo_long_a_id, limit: 8
        t.integer :toooooooo_long_b_id, limit: 8
      end

      connection.create_table :treasures, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.string :type, null: true
        t.integer :looter_id, limit: 8, null: true
        t.string :looter_type, null: true
        t.integer :ship_id, limit: 8, null: true
      end
    end

    # Upstream models assume the schema gives them a primary key; the adapter reports
    # none (ClickHouse sorting keys are not unique), so the harness declares them.
    def assign_model_primary_keys
      ActiveRecord::Base.descendants.each do |model|
        next if model.abstract_class? || model != model.base_class
        next if model.name.nil? || model.name.include?("HABTM") # auto-generated join models
        next if model.primary_key || !model.table_exists?

        if (composite = PRIMARY_KEYS[model.table_name])
          model.primary_key = composite
        elsif model.column_names.include?("id")
          model.primary_key = "id"
        end
      end
    end
  end
end
