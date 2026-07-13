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
    # Tables whose upstream schema declares an explicit primary_key option; nil marks
    # tables whose models must stay primary-key-less even though an id column exists
    # (upstream declares them id: false).
    PRIMARY_KEYS = {
      "cpk_books" => %i[author_id id],
      "cpk_chapters" => %i[author_id id],
      "non_primary_keys" => nil
    }.freeze

    # Tables the harness must reset between tests beyond the fixture tables, which
    # reload every test anyway (decision #15: truncation, no transactions to roll back).
    TABLES = %w[
      1_need_quoting accounts admin_users aircraft audit_logs author_addresses authors
      auto_id_tests books cars carts
      categories categories_posts categorizations clothing_items clubs comments companies computers
      computers_developers contracts
      cpk_books cpk_chapters cpk_orders cpk_reviews customers dashboards developers
      developers_projects
      dog_lovers dogs edges entrants having mateys minimalistics minivans non_primary_keys
      numeric_data organizations parrots people posts projects ratings ship_parts ships
      speedometers subscribers subscriptions taggings tags tires topics
      toooooooooooooooooooooooooooooooooo_long_table_names toys treasures
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

      connection.create_table :admin_users, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.string :settings, null: true
        t.string :parent, null: true
        t.string :spouse, null: true
        t.string :configs, null: true
        t.string :preferences, null: true, default: ""
        t.string :json_data, null: true
        t.string :json_data_empty, null: true, default: ""
        t.string :params, null: true
        t.integer :account_id, limit: 8, null: true
        t.json :json_options, null: true
      end

      connection.create_table :aircraft, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :wheels_count, default: 0
        t.datetime :wheels_owned_at, precision: 6, null: true
        t.datetime :manufactured_at, precision: 6, default: -> { "now64(6)" }
      end

      connection.create_table :audit_logs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :message
        t.integer :developer_id, limit: 8
        t.integer :unvalidated_developer_id, limit: 8, null: true
      end

      # Upstream's table has two auto-populated columns (autoincrement pk + default
      # function); here only the default function qualifies — see skips.yml.
      connection.create_table :auto_id_tests, force: true, order: "auto_id" do |t|
        t.integer :auto_id, limit: 8
        t.integer :value, null: true
        t.datetime :published_at, precision: 6, default: -> { "now64(6)" }
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

      connection.create_table :cars, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :person_id, limit: 8, null: true
        t.string :name, null: true
        t.integer :engines_count, null: true
        t.integer :wheels_count, default: 0
        t.datetime :wheels_owned_at, precision: 6, null: true
        t.integer :bulbs_count, null: true
        t.integer :custom_tires_count, null: true
        t.integer :lock_version, default: 0
        t.datetime :created_at, precision: 6
        t.datetime :updated_at, precision: 6
      end

      # shop_id joins the sorting key, so it stays non-nullable (allow_nullable_key is off).
      connection.create_table :carts, force: true, order: "(shop_id, id)" do |t|
        t.integer :id, limit: 8
        t.integer :shop_id, limit: 8
        t.string :title, null: true
      end

      connection.create_table :categories, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
        t.string :type, null: true
        t.integer :categorizations_count, null: true
      end

      connection.create_table :categories_posts, force: true, order: "(category_id, post_id)" do |t|
        t.integer :category_id, limit: 8
        t.integer :post_id, limit: 8
      end

      connection.create_table :categorizations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :category_id, limit: 8, null: true
        t.string :named_category_name, null: true
        t.integer :post_id, limit: 8, null: true
        t.integer :author_id, limit: 8, null: true
        t.boolean :special, null: true
      end

      connection.create_table :clothing_items, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :clothing_type, null: true
        t.string :color, null: true
        t.string :type, null: true
        t.string :size, null: true
        t.string :description, null: true
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
        # Upstream also has a `comments` column; ClickHouse's analyzer resolves the
        # qualified matcher `comments.*` to a column named like its own table and fails
        # (probed 2026-07-13, UNSUPPORTED_METHOD), so that column stays out of the slice.
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

      connection.create_table :computers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :system, null: true
        t.integer :developer, limit: 8
        t.integer :extendedWarranty, default: 0
        t.integer :timezone, null: true
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :computers_developers, force: true, order: "(computer_id, developer_id)" do |t|
        t.integer :computer_id, limit: 8
        t.integer :developer_id, limit: 8
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :cpk_orders, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :shop_id, limit: 8, null: true
        t.string :status, null: true
        t.integer :books_count, null: true, default: 0
      end

      connection.create_table :cpk_reviews, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :author_id, limit: 8, null: true
        t.integer :number, null: true
        t.integer :rating, null: true
        t.string :comment, null: true
      end

      connection.create_table :customers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :balance, null: true, default: 0
        t.string :address_street, null: true
        t.string :address_city, null: true
        t.string :address_country, null: true
        t.string :gps_location, null: true
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

      connection.create_table :developers_projects, force: true, order: "(developer_id, project_id)" do |t|
        t.integer :developer_id, limit: 8
        t.integer :project_id, limit: 8
        t.date :joined_on, null: true
        t.integer :access_level, null: true, default: 1
      end

      connection.create_table :dashboards, force: true, order: "dashboard_id" do |t|
        t.string :dashboard_id
        t.string :name, null: true
      end

      connection.create_table :dog_lovers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :trained_dogs_count, null: true, default: 0
        t.integer :bred_dogs_count, null: true, default: 0
        t.integer :dogs_count, null: true, default: 0
      end

      connection.create_table :dogs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :trainer_id, limit: 8, null: true
        t.integer :breeder_id, limit: 8, null: true
        t.integer :dog_lover_id, limit: 8, null: true
        t.string :alias, null: true
      end

      connection.create_table :edges, force: true, order: "(source_id, sink_id)" do |t|
        t.integer :source_id, limit: 8
        t.integer :sink_id, limit: 8
      end

      connection.create_table :entrants, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
        t.integer :course_id, limit: 8
      end

      connection.create_table :having, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :where, null: true
      end

      connection.create_table :mateys, force: true, order: "(pirate_id, target_id)" do |t|
        t.integer :pirate_id, limit: 8
        t.integer :target_id, limit: 8
        t.integer :weight, null: true
      end

      connection.create_table :minimalistics, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :expires_at, limit: 8, null: true
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

      # Upstream declares non_primary_keys id: false with a plain id column — the model
      # must stay primary-key-less (PRIMARY_KEYS maps it to nil).
      connection.create_table :non_primary_keys, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.datetime :created_at, precision: 6, null: true
      end

      connection.create_table :organizations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :parrots, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :breed, null: true, default: 0
        t.string :color, null: true
        t.string :parrot_sti_class, null: true
        t.integer :killer_id, limit: 8, null: true
        t.integer :updated_count, null: true, default: 0
        t.datetime :created_at, precision: 0, null: true
        t.datetime :created_on, precision: 0, null: true
        t.datetime :updated_at, precision: 0, null: true
        t.datetime :updated_on, precision: 0, null: true
      end

      connection.create_table :people, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :first_name
        t.integer :primary_contact_id, limit: 8, null: true
        t.string :gender, null: true
        t.integer :number1_fan_id, limit: 8, null: true
        t.integer :lock_version, default: 0
        t.string :comments, null: true
        t.integer :followers_count, default: 0
        t.integer :friends_too_count, default: 0
        t.integer :best_friend_id, limit: 8, null: true
        t.integer :best_friend_of_id, limit: 8, null: true
        t.integer :insures, default: 0
        t.datetime :born_at, precision: 6, null: true
        t.integer :cars_count, default: 0
        t.datetime :created_at, precision: 6
        t.datetime :updated_at, precision: 6
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

      connection.create_table :projects, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.string :type, null: true
        t.integer :firm_id, limit: 8, null: true
        t.integer :mentor_id, limit: 8, null: true
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

      connection.create_table :taggings, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :tag_id, limit: 8, null: true
        t.integer :super_tag_id, limit: 8, null: true
        t.string :taggable_type, null: true
        t.integer :taggable_id, limit: 8, null: true
        t.string :comment, null: true
        t.string :type, null: true
      end

      connection.create_table :tags, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :taggings_count, null: true, default: 0
      end

      connection.create_table :tires, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :car_id, limit: 8, null: true
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

      connection.create_table :toys, force: true, order: "toy_id" do |t|
        t.integer :toy_id, limit: 8
        t.string :name, null: true
        t.integer :pet_id, limit: 8, null: true
        t.datetime :created_at, precision: 6
        t.datetime :updated_at, precision: 6
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

        if PRIMARY_KEYS.key?(model.table_name)
          explicit = PRIMARY_KEYS.fetch(model.table_name)
          model.primary_key = explicit if explicit
        elsif model.column_names.include?("id")
          model.primary_key = "id"
        end
      end
    end
  end
end
