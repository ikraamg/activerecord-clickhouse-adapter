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
      "countries" => :country_id,
      "countries_treaties" => %i[country_id treaty_id],
      "courses_professors" => nil,
      "cpk_order_tags" => %i[order_id tag_id],
      "cpk_books" => %i[author_id id],
      "cpk_chapters" => %i[author_id id],
      "cpk_posts" => %i[title author],
      "jobs_pool" => nil,
      "lessons_students" => nil,
      "non_primary_keys" => nil,
      "parrots_pirates" => nil,
      "parrots_treasures" => nil,
      "peoples_treasures" => nil,
      "treaties" => :treaty_id
    }.freeze

    # Tables the harness must reset between tests beyond the fixture tables, which
    # reload every test anyway (decision #15: truncation, no transactions to roll back).
    TABLES = %w[
      1_need_quoting accounts admin_users aircraft articles articles_magazines articles_tags
      attachments audit_logs author_addresses
      author_favorites authors
      auto_id_tests CamelCase binaries birds book_identifiers books booleans bulbs cake_designers carriers cars carts
      categories categories_posts categorizations chefs citations clothing_items clubs collections
      cold_jokes colleges colnametests columns
      comment_overlapping_counter_caches comments
      companies computers
      computers_developers contracts countries countries_treaties courses courses_professors
      cpk_authors cpk_books cpk_chapters cpk_comments cpk_order_agreements cpk_order_tags
      cpk_orders cpk_posts
      cpk_reviews cpk_tags customer_carriers customers
      dashboards departments developers
      developers_projects
      dog_lovers dogs drink_designers edges electrons engines enrollments entrants entries essays
      eyes faces families
      family_trees funny_jokes goofy_string_id guitars hardbacks having hotels humans
      images interests iris
      integer_limits invoices jobs jobs_pool keyboards kitchens lessons lessons_students line_items lions liquid
      magazines mateys
      member_details member_types members memberships mentors messages mice
      minimalistics minivans molecules movies nodes non_primary_keys
      numeric_data orders organizations owners parrots parrots_pirates parrots_treasures people
      peoples_treasures pets pets_treasures pirates price_estimates prisoners product_types products professors
      program_offerings programs recipes
      post_comments_counts posts projects ratings readers records references rooms
      sections seminars sessions
      sharded_blog_posts sharded_blog_posts_tags sharded_blogs sharded_comments sharded_tags
      ship_parts ships shop_accounts sinks
      speedometers sponsors squeaks string_key_objects students subscribers subscriptions
      taggings tags tasks tires topics
      toooooooooooooooooooooooooooooooooo_long_table_names toys traffic_lights translations treasures treaties
      trees tuning_pegs variants vegetables
      user_comments_counts users warehouse-things weirds wheels zines
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

      connection.create_table :attachments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :record_type
        t.integer :record_id, limit: 8
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

      connection.create_table :articles, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :articles_magazines, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :article_id, limit: 8, null: true
        t.integer :magazine_id, limit: 8, null: true
      end

      connection.create_table :articles_tags, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :article_id, limit: 8, null: true
        t.integer :tag_id, limit: 8, null: true
      end

      connection.create_table :author_favorites, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :author_id, limit: 8, null: true
        t.integer :favorite_author_id, limit: 8, null: true
      end

      connection.create_table :binaries, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.binary :data, null: true
        t.binary :short_data, null: true
        t.blob :blob_data, null: true
      end

      connection.create_table :birds, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.string :color, null: true
        t.integer :pirate_id, limit: 8, null: true
      end

      connection.create_table :book_identifiers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :book_id, limit: 8, null: true
        t.string :id_type
        t.string :id_value
      end

      connection.create_table :booleans, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.boolean :value, null: true
        t.boolean :has_fun, null: false, default: false
      end

      # Upstream names the pk column "ID"; the DATS tests never touch the custom
      # casing, so the slice keeps the conventional name.
      connection.create_table :bulbs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :car_id, limit: 8, null: true
        t.string :name, null: true
        t.boolean :frickinawesome, default: false, null: true
        t.string :color, null: true
      end

      connection.create_table "CamelCase", force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
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
      connection.create_table :carriers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

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

      connection.create_table :cake_designers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :chefs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :employable_id, limit: 8, null: true
        t.string :employable_type, null: true
        t.integer :department_id, limit: 8, null: true
        t.string :employable_list_type, null: true
        t.integer :employable_list_id, limit: 8, null: true
        t.datetime :created_at, precision: 6
        t.datetime :updated_at, precision: 6
      end

      connection.create_table :citations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :book1_id, limit: 8, null: true
        t.integer :book2_id, limit: 8, null: true
        t.integer :citation_id, limit: 8, null: true
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

      connection.create_table :colleges, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
      end

      connection.create_table :colnametests, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :references
      end

      connection.create_table :cold_jokes, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :cold_name, null: true
      end

      connection.create_table :columns, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :record_id, limit: 8, null: true
      end

      connection.create_table :comment_overlapping_counter_caches, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :user_comments_count_id, limit: 8, null: true
        t.integer :post_comments_count_id, limit: 8, null: true
        t.string :commentable_type, null: true
        t.integer :commentable_id, limit: 8, null: true
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

      connection.create_table :cpk_authors, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :cpk_posts, force: true, order: "(title, author)" do |t|
        t.string :title
        t.string :author
      end

      connection.create_table :cpk_comments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :commentable_title, null: true
        t.string :commentable_author, null: true
        t.string :commentable_type, null: true
        t.string :text, null: true
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

      # Upstream countries/treaties key on explicit string ids (habtm with
      # composite-keyed join table).
      connection.create_table :countries, force: true, order: "country_id" do |t|
        t.string :country_id
        t.string :name, null: true
      end

      connection.create_table :countries_treaties, force: true, order: "(country_id, treaty_id)" do |t|
        t.string :country_id
        t.string :treaty_id
      end

      connection.create_table :courses, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
        t.integer :college_id, limit: 8, null: true
      end

      connection.create_table :courses_professors, force: true, order: "(course_id, professor_id)" do |t|
        t.integer :course_id, limit: 8
        t.integer :professor_id, limit: 8
      end

      connection.create_table :cpk_order_tags, force: true, order: "(order_id, tag_id)" do |t|
        t.integer :order_id, limit: 8
        t.integer :tag_id, limit: 8
        t.string :attached_by, null: true
        t.string :attached_reason, null: true
      end

      connection.create_table :cpk_order_agreements, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :order_id, limit: 8, null: true
        t.string :signature, null: true
      end

      connection.create_table :cpk_tags, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
      end

      connection.create_table :customer_carriers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :customer_id, limit: 8, null: true
        t.integer :carrier_id, limit: 8, null: true
      end

      connection.create_table :dashboards, force: true, order: "dashboard_id" do |t|
        t.string :dashboard_id
        t.string :name, null: true
      end

      connection.create_table :departments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :hotel_id, limit: 8, null: true
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

      connection.create_table :electrons, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :molecule_id, limit: 8, null: true
        t.string :name, null: true
      end

      connection.create_table :engines, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :car_id, limit: 8, null: true
      end

      connection.create_table :eyes, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :faces, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :description, null: true
        t.integer :human_id, limit: 8, null: true
        t.integer :polymorphic_human_id, limit: 8, null: true
        t.string :polymorphic_human_type, null: true
        t.integer :poly_human_without_inverse_id, limit: 8, null: true
        t.string :poly_human_without_inverse_type, null: true
        t.integer :puzzled_polymorphic_human_id, limit: 8, null: true
        t.string :puzzled_polymorphic_human_type, null: true
        t.integer :super_human_id, limit: 8, null: true
        t.string :super_human_type, null: true
      end

      connection.create_table :entries, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :entryable_type
        t.integer :entryable_id, limit: 8
        t.integer :account_id, limit: 8
        t.datetime :updated_at, null: true
      end

      connection.create_table :entrants, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
        t.integer :course_id, limit: 8
      end

      # Upstream's writer_id/category_id/author_id are strings: essays fixtures key
      # them by name, not by numeric id.
      connection.create_table :essays, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :type, null: true
        t.string :name, null: true
        t.string :writer_id, null: true
        t.string :writer_type, null: true
        t.string :category_id, null: true
        t.string :author_id, null: true
        t.integer :book_id, limit: 8, null: true
      end

      connection.create_table :enrollments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :program_id, limit: 8, null: true
        t.integer :member_id, limit: 8, null: true
      end

      connection.create_table :families, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :family_trees, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :family_id, limit: 8, null: true
        t.integer :member_id, limit: 8, null: true
        t.string :token, null: true
      end

      connection.create_table :funny_jokes, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :goofy_string_id, force: true, id: false, order: "id" do |t|
        t.string :id, null: false
        t.string :info, null: true
      end

      connection.create_table :guitars, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :color, null: true
      end

      connection.create_table :having, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :where, null: true
      end

      connection.create_table :humans, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :images, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :imageable_identifier, limit: 8, null: true
        t.string :imageable_class, null: true
      end

      connection.create_table :interests, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :topic, null: true
        t.integer :human_id, limit: 8, null: true
        t.integer :polymorphic_human_id, limit: 8, null: true
        t.string :polymorphic_human_type, null: true
        t.integer :zine_id, limit: 8, null: true
      end

      # Upstream names this table :iris (singular) — Iris.table_name resolves to it.
      connection.create_table :iris, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :eye_id, limit: 8, null: true
        t.string :color, null: true
      end

      connection.create_table :integer_limits, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :c_int_without_limit, null: true
        (1..8).each do |i|
          t.integer :"c_int_#{i}", limit: i, null: true
        end
      end

      connection.create_table :invoices, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :balance, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :jobs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :ideal_reference_id, limit: 8, null: true
      end

      connection.create_table :drink_designers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :jobs_pool, force: true, order: "(job_id, user_id)" do |t|
        t.integer :job_id, limit: 8
        t.integer :user_id, limit: 8
      end

      connection.create_table :hardbacks, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :hotels, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :keyboards, force: true, order: "key_number" do |t|
        t.integer :key_number, limit: 8
        t.string :name, null: true
      end

      connection.create_table :kitchens, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :lessons, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :lessons_students, force: true, order: "(lesson_id, student_id)" do |t|
        t.integer :lesson_id, limit: 8
        t.integer :student_id, limit: 8
      end

      connection.create_table :liquid, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :line_items, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :invoice_id, limit: 8, null: true
        t.integer :amount, null: true
      end

      connection.create_table :lions, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :gender, null: true
        t.boolean :is_vegetarian, default: false
      end

      connection.create_table :mateys, force: true, order: "(pirate_id, target_id)" do |t|
        t.integer :pirate_id, limit: 8
        t.integer :target_id, limit: 8
        t.integer :weight, null: true
      end

      connection.create_table :members, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :member_type_id, limit: 8, null: true
        t.string :admittable_type, null: true
        t.integer :admittable_id, limit: 8, null: true
      end

      # Upstream's type column is an integer backed by an enum (STI dark corner).
      connection.create_table :member_details, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :member_id, limit: 8, null: true
        t.integer :organization_id, limit: 8, null: true
        t.string :extra_data, null: true
      end

      connection.create_table :member_types, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :mentors, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :memberships, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.datetime :joined_on, precision: 6, null: true
        t.integer :club_id, limit: 8, null: true
        t.integer :member_id, limit: 8, null: true
        t.boolean :favorite, default: false
        t.integer :type, null: true
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :magazines, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :messages, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :subject, null: true
        t.datetime :updated_at, null: true
      end

      connection.create_table :mice, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
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

      connection.create_table :molecules, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :liquid_id, limit: 8, null: true
        t.string :name, null: true
      end

      connection.create_table :nodes, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :tree_id, limit: 8, null: true
        t.integer :parent_id, limit: 8, null: true
        t.string :name, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      # Upstream declares non_primary_keys id: false with a plain id column — the model
      # must stay primary-key-less (PRIMARY_KEYS maps it to nil).
      connection.create_table :non_primary_keys, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.datetime :created_at, precision: 6, null: true
      end

      connection.create_table :orders, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :billing_customer_id, limit: 8, null: true
        t.integer :shipping_customer_id, limit: 8, null: true
      end

      connection.create_table :organizations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :owners, force: true, order: "owner_id" do |t|
        t.integer :owner_id, limit: 8
        t.string :name, null: true
        t.datetime :updated_at, precision: 6, null: true
        t.datetime :happy_at, precision: 6, null: true
        t.string :essay_id, null: true
      end

      connection.create_table :parrots_pirates, force: true, order: "(parrot_id, pirate_id)" do |t|
        t.integer :parrot_id, limit: 8
        t.integer :pirate_id, limit: 8
      end

      connection.create_table :parrots_treasures, force: true, order: "(parrot_id, treasure_id)" do |t|
        t.integer :parrot_id, limit: 8
        t.integer :treasure_id, limit: 8
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

      connection.create_table :peoples_treasures, force: true, order: "(rich_person_id, treasure_id)" do |t|
        t.integer :rich_person_id, limit: 8
        t.integer :treasure_id, limit: 8
      end

      connection.create_table :pets, force: true, order: "pet_id" do |t|
        t.integer :pet_id, limit: 8
        t.string :name, null: true
        t.integer :owner_id, limit: 8, null: true
        t.datetime :created_at, precision: 6
        t.datetime :updated_at, precision: 6
      end

      connection.create_table :pets_treasures, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :treasure_id, limit: 8, null: true
        t.integer :pet_id, limit: 8, null: true
        t.string :rainbow_color, null: true
      end

      connection.create_table :pirates, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :catchphrase, null: true
        t.integer :parrot_id, limit: 8, null: true
        t.integer :non_validated_parrot_id, limit: 8, null: true
        t.datetime :created_on, precision: 6, null: true
        t.datetime :updated_on, precision: 6, null: true
      end

      connection.create_table :collections, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :products, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :collection_id, limit: 8, null: true
        t.integer :type_id, limit: 8, null: true
        t.string :name, null: true
        t.decimal :price, null: true
      end

      connection.create_table :product_types, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :variants, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :product_id, limit: 8, null: true
        t.string :name, null: true
      end

      connection.create_table :vegetables, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :seller_id, limit: 8, null: true
        t.string :custom_type, null: true
      end

      connection.create_table :price_estimates, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :estimate_of_type, null: true
        t.integer :estimate_of_id, limit: 8, null: true
        t.integer :price, null: true
        t.string :currency, null: true
      end

      connection.create_table :post_comments_counts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :comments_count, default: 0, null: true
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

      connection.create_table :readers, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :post_id, limit: 8
        t.integer :person_id, limit: 8
        t.boolean :skimmer, default: false, null: true
        t.integer :first_post_id, limit: 8, null: true
      end

      connection.create_table :program_offerings, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :club_id, limit: 8, null: true
        t.integer :program_id, limit: 8, null: true
        t.datetime :start_date, precision: 6, null: true
      end

      connection.create_table :programs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :prisoners, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :ship_id, limit: 8, null: true
      end

      connection.create_table :professors, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name
      end

      connection.create_table :ratings, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :comment_id, limit: 8, null: true
        t.integer :value, null: true
      end

      connection.create_table :references, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :person_id, limit: 8, null: true
        t.integer :job_id, limit: 8, null: true
        t.boolean :favorite, null: true
        t.integer :lock_version, default: 0, null: true
      end

      connection.create_table :records, force: true, order: "id" do |t|
        t.integer :id, limit: 8
      end

      connection.create_table :sections, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :short_name, null: true
        t.integer :session_id, limit: 8, null: true
        t.integer :seminar_id, limit: 8, null: true
      end

      connection.create_table :seminars, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :sessions, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.date :start_date, null: true
        t.date :end_date, null: true
        t.string :name, null: true
      end

      connection.create_table :sharded_blogs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
      end

      connection.create_table :sharded_blog_posts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :title, null: true
        t.string :parent_type, null: true
        t.integer :parent_id, limit: 8, null: true
        t.integer :blog_id, limit: 8, null: true
        t.integer :revision, null: true
      end

      connection.create_table :sharded_comments, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :body, null: true
        t.integer :blog_post_id, limit: 8, null: true
        t.integer :blog_id, limit: 8, null: true
      end

      connection.create_table :sharded_tags, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :blog_id, limit: 8, null: true
      end

      connection.create_table :sharded_blog_posts_tags, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :blog_id, limit: 8, null: true
        t.integer :blog_post_id, limit: 8, null: true
        t.integer :tag_id, limit: 8, null: true
      end

      connection.create_table :rooms, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :user_id, limit: 8, null: true
        t.integer :owner_id, limit: 8, null: true
        t.integer :landlord_id, limit: 8, null: true
        t.integer :tenant_id, limit: 8, null: true
      end

      connection.create_table :sinks, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :kitchen_id, limit: 8, null: true
      end

      connection.create_table :ship_parts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.integer :ship_id, limit: 8, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :shop_accounts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :customer_id, limit: 8, null: true
        t.integer :customer_carrier_id, limit: 8, null: true
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

      connection.create_table :squeaks, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :mouse_id, limit: 8, null: true
      end

      connection.create_table :speedometers, force: true, order: "speedometer_id" do |t|
        t.string :speedometer_id
        t.string :name, null: true
        t.string :dashboard_id, null: true
      end

      connection.create_table :sponsors, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :club_id, limit: 8, null: true
        t.string :sponsorable_type, null: true
        t.integer :sponsorable_id, limit: 8, null: true
        t.string :sponsor_type, null: true
        t.integer :sponsor_id, limit: 8, null: true
      end

      connection.create_table :students, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.boolean :active, null: true
        t.integer :college_id, limit: 8, null: true
      end

      connection.create_table :movies, force: true, id: false, order: "movieid" do |t|
        t.integer :movieid, limit: 8
        t.string :name, null: true
      end

      connection.create_table :string_key_objects, force: true, id: false, order: "id" do |t|
        t.string :id, null: false
        t.string :name, null: true
        t.integer :lock_version, null: false, default: 0
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

      connection.create_table :recipes, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :chef_id, limit: 8, null: true
        t.integer :hotel_id, limit: 8, null: true
      end

      connection.create_table :tasks, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.datetime :starting, null: true
        t.datetime :ending, null: true
      end

      connection.create_table :translations, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :locale
        t.string :key
        t.string :value
        t.integer :attachment_id, limit: 8, null: true
      end

      connection.create_table :tuning_pegs, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :guitar_id, limit: 8, null: true
        t.float :pitch, null: true
      end

      connection.create_table :tires, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :car_id, limit: 8, null: true
      end

      connection.create_table :traffic_lights, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :location, null: true
        t.string :state, null: true
        t.text :long_state
        t.datetime :created_at, null: true
        t.datetime :updated_at, null: true
      end

      connection.create_table :treaties, force: true, order: "treaty_id" do |t|
        t.string :treaty_id
        t.string :name, null: true
      end

      connection.create_table :users, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :token, null: true
        t.string :auth_token, null: true
        t.string :password_digest, null: true
        t.string :recovery_password_digest, null: true
        t.datetime :created_at, precision: 6, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :user_comments_counts, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :comments_count, default: 0, null: true
      end

      connection.create_table :weirds, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string "a$b", null: true
        t.string "なまえ", null: true
        t.string :from, null: true
      end

      connection.create_table "warehouse-things", force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :value, null: true
      end

      connection.create_table :wheels, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.integer :size, null: true
        t.string :wheelable_type, null: true
        t.integer :wheelable_id, limit: 8, null: true
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

      connection.create_table :trees, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :name, null: true
        t.datetime :updated_at, precision: 6, null: true
      end

      connection.create_table :zines, force: true, order: "id" do |t|
        t.integer :id, limit: 8
        t.string :title, null: true
      end
    end

    # Upstream models assume the schema gives them a primary key; the adapter reports
    # none (ClickHouse sorting keys are not unique), so the harness declares them.
    # Abstract classes qualify too when they pin a table (LoosePerson → people).
    def assign_model_primary_keys
      ActiveRecord::Base.descendants.each do |model|
        next if model.abstract_class? ? model.table_name.nil? : model != model.base_class
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
