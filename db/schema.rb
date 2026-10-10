# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_10_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "audit_entries", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_id"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.bigint "subject_id"
    t.string "subject_type", null: false
    t.text "summary"
    t.string "summary_i18n_key"
    t.bigint "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["actor_id"], name: "index_audit_entries_on_actor_id"
    t.index ["created_at", "id"], name: "index_audit_entries_on_created_at_and_id"
    t.index ["subject_type", "subject_id"], name: "index_audit_entries_on_subject_type_and_subject_id"
    t.index ["tenant_id", "created_at"], name: "index_audit_entries_on_tenant_id_and_created_at"
    t.index ["tenant_id"], name: "index_audit_entries_on_tenant_id"
  end

  create_table "android_package_registrations", force: :cascade do |t|
    t.bigint "app_id"
    t.datetime "created_at", null: false
    t.string "developer_account"
    t.string "google_package_state"
    t.string "key_fingerprint_sha256"
    t.string "key_state"
    t.datetime "last_checked_at"
    t.text "last_error"
    t.string "package_name", null: false
    t.string "policy_strategy"
    t.string "state", default: "pending", null: false
    t.bigint "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_android_package_registrations_on_app_id"
    t.index ["package_name"], name: "index_android_package_registrations_on_package_name", unique: true
  end

  create_table "android_signing_keys", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key_alias", null: false
    t.text "key_password", null: false
    t.text "keystore", null: false
    t.text "keystore_password", null: false
    t.datetime "updated_at", null: false
    t.index ["checksum"], name: "index_android_signing_keys_on_checksum", unique: true
  end

  create_table "app_api_tokens", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.datetime "expires_at"
    t.string "last_four", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.text "scopes", default: ["publish"], null: false, array: true
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_app_api_tokens_on_app_id"
    t.index ["created_by_id"], name: "index_app_api_tokens_on_created_by_id"
    t.index ["token_digest"], name: "index_app_api_tokens_on_token_digest", unique: true
  end

  create_table "app_maintenance_billings", force: :cascade do |t|
    t.integer "amount_cents", default: 200, null: false
    t.bigint "app_id", null: false
    t.string "billing_period", default: "monthly", null: false
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "hyperswitch_mandate_id"
    t.datetime "lapsed_at"
    t.bigint "last_payment_id"
    t.datetime "next_charge_at"
    t.datetime "paid_through"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["app_id"], name: "index_app_maintenance_billings_on_app_id", unique: true
    t.index ["next_charge_at"], name: "index_app_maintenance_billings_on_next_charge_at"
    t.index ["status"], name: "index_app_maintenance_billings_on_status"
    t.index ["user_id"], name: "index_app_maintenance_billings_on_user_id"
    t.check_constraint "amount_cents > 0", name: "app_maintenance_billings_amount_positive"
  end

  create_table "apple_keys", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "issuer_id", null: false
    t.string "key_id", null: false
    t.string "private_key", null: false
    t.datetime "updated_at", null: false
    t.index ["checksum"], name: "index_apple_keys_on_checksum"
    t.index ["issuer_id"], name: "index_apple_keys_on_issuer_id"
    t.index ["key_id"], name: "index_apple_keys_on_key_id"
  end

  create_table "apple_keys_devices", id: false, force: :cascade do |t|
    t.bigint "apple_key_id", null: false
    t.bigint "device_id", null: false
    t.index ["apple_key_id", "device_id"], name: "index_apple_keys_devices_on_apple_key_id_and_device_id"
    t.index ["device_id", "apple_key_id"], name: "index_apple_keys_devices_on_device_id_and_apple_key_id"
  end

  create_table "apple_teams", force: :cascade do |t|
    t.bigint "apple_key_id"
    t.datetime "created_at", null: false
    t.string "display_name", default: "", null: false
    t.string "name", null: false
    t.string "team_id"
    t.datetime "updated_at", null: false
    t.index ["apple_key_id"], name: "index_apple_teams_on_apple_key_id"
  end

  create_table "apps", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.jsonb "available_regions", default: [], null: false
    t.string "category"
    t.boolean "contains_ads"
    t.string "content_rating"
    t.datetime "created_at", null: false
    t.boolean "data_safety_collects"
    t.string "data_safety_deletion_url"
    t.boolean "data_safety_encrypted"
    t.boolean "data_safety_shared"
    t.jsonb "data_safety_types", default: [], null: false
    t.boolean "developer_verified", default: false, null: false
    t.string "description"
    t.boolean "editors_pick", default: false, null: false
    t.boolean "featured", default: false, null: false
    t.boolean "has_in_app_purchases"
    t.datetime "listed_at"
    t.string "listing_status", default: "draft", null: false
    t.bigint "migrated_downloads", default: 0, null: false
    t.decimal "migrated_rating_average", precision: 3, scale: 2
    t.integer "migrated_rating_count", default: 0, null: false
    t.datetime "migrated_recorded_at"
    t.bigint "migrated_recorded_by_id"
    t.text "migrated_source_note"
    t.string "name", null: false
    t.string "play_package_name"
    t.string "play_publish_track", default: "internal", null: false
    t.datetime "play_setup_checked_at"
    t.text "play_setup_message"
    t.string "play_setup_status", default: "unchecked", null: false
    t.string "privacy_policy_url"
    t.string "promo_video_youtube_id"
    t.string "publisher_alias"
    t.bigint "publisher_profile_id"
    t.text "reviewer_access_instructions"
    t.string "short_description"
    t.bigint "tenant_id"
    t.datetime "updated_at", null: false
    t.boolean "updater_enabled", default: true, null: false
    t.datetime "verification_checked_at"
    t.boolean "verification_key_registered", default: false, null: false
    t.boolean "verification_package_registered", default: false, null: false
    t.index ["name"], name: "index_apps_on_name"
    t.index ["play_package_name"], name: "index_apps_on_play_package_name", unique: true, where: "(play_package_name IS NOT NULL)"
    t.index ["publisher_profile_id"], name: "index_apps_on_publisher_profile_id"
    t.index ["tenant_id"], name: "index_apps_on_tenant_id"
  end

  create_table "apps_users", id: false, force: :cascade do |t|
    t.bigint "app_id", null: false
    t.boolean "owner", default: false, null: false
    t.integer "role", default: 0, null: false
    t.bigint "user_id", null: false
    t.index ["app_id", "user_id"], name: "index_apps_users_on_app_id_and_user_id", unique: true
    t.index ["user_id", "app_id"], name: "index_apps_users_on_user_id_and_app_id", unique: true
  end

  create_table "backups", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled"
    t.integer "enabled_apps", default: [], array: true
    t.boolean "enabled_database", default: true
    t.string "key", null: false
    t.integer "max_keeps", default: -1
    t.string "notification"
    t.string "schedule", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_backups_on_key"
  end

  create_table "catalog_index_signing_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key_id", null: false
    t.datetime "last_signed_at"
    t.text "private_key_pem", null: false
    t.string "public_key", null: false
    t.datetime "updated_at", null: false
    t.index ["public_key"], name: "index_catalog_index_signing_keys_on_public_key", unique: true
  end

  create_table "catalog_index_snapshots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "generated_at", null: false
    t.text "index_json", null: false
    t.text "signature", null: false
    t.string "signing_key_id"
    t.string "tenant_key", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_key"], name: "index_catalog_index_snapshots_on_tenant_key", unique: true
  end

  create_table "channels", force: :cascade do |t|
    t.string "bundle_id", default: "*"
    t.string "device_type", null: false
    t.string "download_filename_type"
    t.string "git_url"
    t.string "key"
    t.string "name", null: false
    t.string "password"
    t.bigint "scheme_id"
    t.string "slug", null: false
    t.string "track", default: "production", null: false
    t.index ["bundle_id"], name: "index_channels_on_bundle_id"
    t.index ["device_type"], name: "index_channels_on_device_type"
    t.index ["name"], name: "index_channels_on_name"
    t.index ["scheme_id", "device_type"], name: "index_channels_on_scheme_id_and_device_type"
    t.index ["slug"], name: "index_channels_on_slug", unique: true
    t.index ["track"], name: "index_channels_on_track"
    t.check_constraint "track::text = ANY (ARRAY['internal'::character varying::text, 'closed'::character varying::text, 'open'::character varying::text, 'production'::character varying::text])", name: "channels_track_allowed_values"
  end

  create_table "channels_web_hooks", id: false, force: :cascade do |t|
    t.bigint "channel_id", null: false
    t.datetime "created_at", precision: nil
    t.bigint "web_hook_id", null: false
    t.index ["channel_id", "web_hook_id"], name: "index_channels_web_hooks_on_channel_id_and_web_hook_id"
    t.index ["web_hook_id", "channel_id"], name: "index_channels_web_hooks_on_web_hook_id_and_channel_id"
  end

  create_table "collection_apps", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.bigint "collection_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_collection_apps_on_app_id"
    t.index ["collection_id", "app_id"], name: "index_collection_apps_on_collection_id_and_app_id", unique: true
    t.index ["collection_id"], name: "index_collection_apps_on_collection_id"
  end

  create_table "collections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.bigint "tenant_id"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_collections_on_slug", unique: true
    t.index ["tenant_id"], name: "index_collections_on_tenant_id"
  end

  create_table "debug_file_metadata", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.bigint "debug_file_id", null: false
    t.string "object"
    t.integer "size"
    t.string "type"
    t.datetime "updated_at", null: false
    t.string "uuid"
    t.index ["debug_file_id"], name: "index_debug_file_metadata_on_debug_file_id"
  end

  create_table "debug_files", force: :cascade do |t|
    t.bigint "app_id"
    t.string "build_version"
    t.string "checksum"
    t.datetime "created_at", null: false
    t.string "device_type"
    t.string "file"
    t.string "release_version"
    t.datetime "updated_at", null: false
    t.index ["app_id", "device_type"], name: "index_debug_files_on_app_id_and_device_type"
    t.index ["app_id"], name: "index_debug_files_on_app_id"
    t.index ["id", "device_type"], name: "index_debug_files_on_id_and_device_type"
  end

  create_table "debug_symbols", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.string "file", null: false
    t.string "kind", null: false
    t.bigint "release_id", null: false
    t.bigint "size", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_debug_symbols_on_app_id"
    t.index ["release_id", "kind"], name: "index_debug_symbols_on_release_id_and_kind", unique: true
    t.index ["release_id"], name: "index_debug_symbols_on_release_id"
  end

  create_table "devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_id"
    t.string "model"
    t.string "name"
    t.string "platform"
    t.string "status"
    t.string "udid", null: false
    t.datetime "updated_at", null: false
    t.index ["udid"], name: "index_devices_on_udid"
  end

  create_table "devices_releases", id: false, force: :cascade do |t|
    t.bigint "device_id", null: false
    t.bigint "release_id", null: false
    t.index ["device_id", "release_id"], name: "index_devices_releases_on_device_id_and_release_id"
    t.index ["release_id", "device_id"], name: "index_devices_releases_on_release_id_and_device_id"
  end

  create_table "good_job_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "callback_priority"
    t.text "callback_queue_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "discarded_at"
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.text "on_discard"
    t.text "on_finish"
    t.text "on_success"
    t.jsonb "serialized_properties"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id", null: false
    t.datetime "created_at", null: false
    t.interval "duration"
    t.text "error"
    t.text "error_backtrace", array: true
    t.integer "error_event", limit: 2
    t.datetime "finished_at"
    t.text "job_class"
    t.uuid "process_id"
    t.text "queue_name"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_job_executions_on_active_job_id_and_created_at"
    t.index ["process_id", "created_at"], name: "index_good_job_executions_on_process_id_and_created_at"
  end

  create_table "good_job_processes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lock_type", limit: 2
    t.jsonb "state"
    t.datetime "updated_at", null: false
  end

  create_table "good_job_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "key"
    t.datetime "updated_at", null: false
    t.jsonb "value"
    t.index ["key"], name: "index_good_job_settings_on_key", unique: true
  end

  create_table "good_jobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "active_job_id"
    t.uuid "batch_callback_id"
    t.uuid "batch_id"
    t.text "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "cron_at"
    t.text "cron_key"
    t.text "error"
    t.integer "error_event", limit: 2
    t.integer "executions_count"
    t.datetime "finished_at"
    t.boolean "is_discrete"
    t.text "job_class"
    t.text "labels", array: true
    t.datetime "locked_at"
    t.uuid "locked_by_id"
    t.datetime "performed_at"
    t.integer "priority"
    t.text "queue_name"
    t.uuid "retried_good_job_id"
    t.datetime "scheduled_at"
    t.jsonb "serialized_params"
    t.datetime "updated_at", null: false
    t.index ["active_job_id", "created_at"], name: "index_good_jobs_on_active_job_id_and_created_at"
    t.index ["batch_callback_id"], name: "index_good_jobs_on_batch_callback_id", where: "(batch_callback_id IS NOT NULL)"
    t.index ["batch_id"], name: "index_good_jobs_on_batch_id", where: "(batch_id IS NOT NULL)"
    t.index ["concurrency_key"], name: "index_good_jobs_on_concurrency_key_when_unfinished", where: "(finished_at IS NULL)"
    t.index ["cron_key", "created_at"], name: "index_good_jobs_on_cron_key_and_created_at_cond", where: "(cron_key IS NOT NULL)"
    t.index ["cron_key", "cron_at"], name: "index_good_jobs_on_cron_key_and_cron_at_cond", unique: true, where: "(cron_key IS NOT NULL)"
    t.index ["finished_at"], name: "index_good_jobs_jobs_on_finished_at", where: "((retried_good_job_id IS NULL) AND (finished_at IS NOT NULL))"
    t.index ["labels"], name: "index_good_jobs_on_labels", where: "(labels IS NOT NULL)", using: :gin
    t.index ["locked_by_id"], name: "index_good_jobs_on_locked_by_id", where: "(locked_by_id IS NOT NULL)"
    t.index ["priority", "created_at"], name: "index_good_job_jobs_for_candidate_lookup", where: "(finished_at IS NULL)"
    t.index ["priority", "created_at"], name: "index_good_jobs_jobs_on_priority_created_at_when_unfinished", order: { priority: "DESC NULLS LAST" }, where: "(finished_at IS NULL)"
    t.index ["priority", "scheduled_at"], name: "index_good_jobs_on_priority_scheduled_at_unfinished_unlocked", where: "((finished_at IS NULL) AND (locked_by_id IS NULL))"
    t.index ["queue_name", "scheduled_at"], name: "index_good_jobs_on_queue_name_and_scheduled_at", where: "(finished_at IS NULL)"
    t.index ["scheduled_at"], name: "index_good_jobs_on_scheduled_at", where: "(finished_at IS NULL)"
  end

  create_table "listing_edits", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "committed_at"
    t.datetime "created_at", null: false
    t.datetime "discarded_at"
    t.bigint "editor_id"
    t.jsonb "staged_attributes", default: {}, null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "status"], name: "index_listing_edits_on_app_id_and_status"
    t.index ["app_id"], name: "index_listing_edits_on_app_id"
    t.index ["app_id"], name: "index_listing_edits_on_app_id_when_draft", unique: true, where: "((status)::text = 'draft'::text)"
    t.index ["editor_id"], name: "index_listing_edits_on_editor_id"
  end

  create_table "listing_graphics", force: :cascade do |t|
    t.string "alt_text"
    t.bigint "app_id", null: false
    t.integer "byte_size", null: false
    t.string "content_type", null: false
    t.datetime "created_at", null: false
    t.string "device", default: "phone", null: false
    t.integer "height", null: false
    t.string "kind", null: false
    t.integer "position", default: 0, null: false
    t.string "sha256"
    t.string "storage_key"
    t.datetime "updated_at", null: false
    t.integer "width", null: false
    t.index ["app_id", "device"], name: "index_listing_graphics_on_app_id_device_feature_graphic", unique: true, where: "((kind)::text = 'feature_graphic'::text)"
    t.index ["app_id", "kind", "device", "position"], name: "index_listing_graphics_on_app_id_kind_device_position", unique: true
    t.check_constraint "byte_size > 0", name: "listing_graphics_byte_size_positive"
    t.check_constraint "device::text = 'phone'::text", name: "listing_graphics_device_known"
    t.check_constraint "kind::text = 'screenshot'::text OR kind::text = 'feature_graphic'::text", name: "listing_graphics_kind_known"
    t.check_constraint "width > 0 AND height > 0", name: "listing_graphics_dimensions_positive"
  end

  create_table "metadata", force: :cascade do |t|
    t.jsonb "activities", default: [], null: false
    t.string "build_version"
    t.string "bundle_id"
    t.jsonb "capabilities", default: [], null: false
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.jsonb "deep_links", default: [], null: false
    t.jsonb "developer_certs", default: [], null: false
    t.string "device", null: false
    t.jsonb "devices", default: [], null: false
    t.jsonb "entitlements", default: {}, null: false
    t.jsonb "features", default: [], null: false
    t.string "min_sdk_version"
    t.jsonb "mobileprovision", default: {}, null: false
    t.string "name"
    t.jsonb "native_codes", default: [], null: false
    t.jsonb "permissions", default: [], null: false
    t.string "platform"
    t.bigint "release_id"
    t.string "release_type"
    t.string "release_version"
    t.jsonb "services", default: [], null: false
    t.integer "size"
    t.string "target_sdk_version"
    t.datetime "updated_at", null: false
    t.jsonb "url_schemes", default: [], null: false
    t.bigint "user_id"
    t.index ["checksum"], name: "index_metadata_on_checksum"
    t.index ["release_id"], name: "index_metadata_on_release_id"
    t.index ["user_id"], name: "index_metadata_on_user_id"
  end

  create_table "migrated_comments", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.string "author_name", null: false
    t.text "body"
    t.date "commented_on", null: false
    t.datetime "created_at", null: false
    t.text "developer_reply"
    t.datetime "developer_replied_at"
    t.integer "helpful_count", default: 0, null: false
    t.integer "rating", null: false
    t.bigint "recorded_by_id"
    t.text "source_note", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "commented_on"], name: "index_migrated_comments_on_app_id_and_commented_on"
    t.index ["app_id"], name: "index_migrated_comments_on_app_id"
    t.index ["recorded_by_id"], name: "index_migrated_comments_on_recorded_by_id"
  end

  create_table "payments", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.bigint "app_id", null: false
    t.string "billing_period"
    t.text "client_secret"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "hyperswitch_mandate_id"
    t.string "hyperswitch_payment_id"
    t.text "hyperswitch_raw_response"
    t.datetime "next_charge_at"
    t.datetime "paid_at"
    t.string "purpose", default: "listing_fee", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["app_id", "purpose"], name: "index_payments_on_app_id_and_purpose"
    t.index ["app_id"], name: "index_payments_on_app_id"
    t.index ["hyperswitch_mandate_id"], name: "index_payments_on_hyperswitch_mandate_id"
    t.index ["hyperswitch_payment_id"], name: "index_payments_on_hyperswitch_payment_id", unique: true
    t.index ["next_charge_at"], name: "index_payments_on_next_charge_at"
    t.index ["user_id"], name: "index_payments_on_user_id"
  end

  create_table "payouts", force: :cascade do |t|
    t.integer "amount_cents", null: false
    t.string "bpay_payout_id"
    t.datetime "cancelled_at"
    t.datetime "confirmed_at"
    t.string "connector"
    t.datetime "created_at", null: false
    t.string "currency", default: "usd", null: false
    t.string "customer_id"
    t.string "failure_reason"
    t.datetime "fulfilled_at"
    t.string "merchant_id"
    t.string "payout_method_id"
    t.bigint "publisher_profile_id", null: false
    t.text "raw_response"
    t.string "status", default: "created", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["bpay_payout_id"], name: "index_payouts_on_bpay_payout_id", unique: true
    t.index ["publisher_profile_id"], name: "index_payouts_on_publisher_profile_id"
    t.index ["status"], name: "index_payouts_on_status"
    t.index ["user_id"], name: "index_payouts_on_user_id"
  end

  create_table "play_credentials", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "project_id"
    t.string "service_account_email", null: false
    t.text "service_account_json", null: false
    t.datetime "updated_at", null: false
    t.index ["checksum"], name: "index_play_credentials_on_checksum", unique: true
  end

  create_table "play_upload_keys", force: :cascade do |t|
    t.string "checksum", null: false
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key_alias", null: false
    t.text "key_password", null: false
    t.text "keystore", null: false
    t.text "keystore_password", null: false
    t.datetime "updated_at", null: false
    t.index ["checksum"], name: "index_play_upload_keys_on_checksum", unique: true
  end

  create_table "publisher_profiles", force: :cascade do |t|
    t.string "contact_email", null: false
    t.string "country", null: false
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "kind", default: "individual", null: false
    t.string "legal_name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_publisher_profiles_on_user_id", unique: true
  end

  create_table "release_uploads", force: :cascade do |t|
    t.bigint "channel_id"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "declared_size", null: false
    t.datetime "dispatched_at"
    t.text "error"
    t.string "etag"
    t.datetime "expires_at"
    t.string "filename", null: false
    t.jsonb "form_options", default: {}, null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "multipart_upload_id"
    t.bigint "part_size"
    t.bigint "release_id"
    t.datetime "stage1_at"
    t.string "staging_key"
    t.string "state", default: "awaiting_bytes", null: false
    t.datetime "updated_at", null: false
    t.datetime "uploaded_at"
    t.bigint "uploaded_size"
    t.bigint "user_id"
    t.index ["channel_id"], name: "index_release_uploads_on_channel_id"
    t.index ["release_id"], name: "index_release_uploads_on_release_id", unique: true
    t.index ["staging_key"], name: "index_release_uploads_on_staging_key", unique: true
    t.index ["state", "expires_at"], name: "index_release_uploads_on_state_and_expires_at"
    t.index ["user_id"], name: "index_release_uploads_on_user_id"
    t.check_constraint "declared_size > 0", name: "release_uploads_declared_size_positive"
    t.check_constraint "part_size IS NULL OR part_size > 0", name: "release_uploads_part_size_positive"
  end

  create_table "releases", force: :cascade do |t|
    t.jsonb "abis", default: [], null: false
    t.string "asset_delivery_error"
    t.string "asset_delivery_state"
    t.datetime "asset_delivery_state_at"
    t.string "asset_pack_type"
    t.jsonb "automated_review_reasons", default: [], null: false
    t.jsonb "automated_review_trackers", default: [], null: false
    t.string "automated_review_status", default: "not_run", null: false
    t.string "automated_review_verdict"
    t.datetime "automated_reviewed_at"
    t.string "branch"
    t.boolean "brotli_compressed", default: false, null: false
    t.string "build_version"
    t.string "bundle_id"
    t.jsonb "changelog", null: false
    t.bigint "channel_id"
    t.text "ci_compile_error"
    t.datetime "ci_compile_finished_at"
    t.string "ci_compile_state"
    t.datetime "ci_compile_state_at"
    t.string "ci_url"
    t.string "compressed_apks_storage_key"
    t.bigint "compressed_size"
    t.datetime "created_at", null: false
    t.jsonb "custom_fields", default: [], null: false
    t.string "device_type"
    t.string "file"
    t.string "file_sha256"
    t.string "file_storage_key"
    t.string "git_commit"
    t.bigint "github_download_count", default: 0, null: false
    t.datetime "github_download_count_synced_at"
    t.string "icon"
    t.string "icon_sha256"
    t.string "icon_storage_key"
    t.integer "min_sdk_version"
    t.datetime "mtproto_archived_at"
    t.string "mtproto_archived_location"
    t.string "name"
    t.bigint "original_size"
    t.string "patched_file_path"
    t.string "patched_file_storage_key"
    t.jsonb "permissions", default: [], null: false
    t.datetime "play_approval_expires_at"
    t.datetime "play_approval_requested_at"
    t.string "play_approval_status", default: "not_requested", null: false
    t.datetime "play_approved_at"
    t.bigint "play_approved_by_id"
    t.string "play_edit_id"
    t.text "play_publish_error"
    t.string "play_publish_status", default: "not_published", null: false
    t.datetime "play_published_at"
    t.datetime "play_rejected_at"
    t.bigint "play_rejected_by_id"
    t.boolean "play_store_target", default: false, null: false
    t.string "release_type"
    t.string "release_version"
    t.jsonb "required_features", default: [], null: false
    t.integer "rollout_percentage", default: 100, null: false
    t.string "rollout_status", default: "active", null: false
    t.jsonb "screen_densities", default: [], null: false
    t.boolean "signed", default: false, null: false
    t.string "signing_key_checksum"
    t.string "source"
    t.string "status", default: "available", null: false
    t.integer "target_sdk_version"
    t.string "universal_apk_sha256"
    t.bigint "universal_apk_size"
    t.string "universal_apk_storage_key"
    t.datetime "updated_at", null: false
    t.integer "version", null: false
    t.index ["asset_pack_type"], name: "index_releases_on_asset_pack_type"
    t.index ["build_version"], name: "index_releases_on_build_version"
    t.index ["bundle_id"], name: "index_releases_on_bundle_id"
    t.index ["channel_id", "version"], name: "index_releases_on_channel_id_and_version", unique: true
    t.index ["ci_compile_state"], name: "index_releases_on_ci_compile_state"
    t.index ["mtproto_archived_at"], name: "index_releases_on_mtproto_archived_at"
    t.index ["play_approval_expires_at"], name: "index_releases_on_play_approval_expires_at"
    t.index ["automated_review_status"], name: "index_releases_on_automated_review_status"
    t.index ["automated_review_verdict"], name: "index_releases_on_automated_review_verdict"
    t.index ["play_approval_status"], name: "index_releases_on_play_approval_status"
    t.index ["play_approved_by_id"], name: "index_releases_on_play_approved_by_id"
    t.index ["play_publish_status"], name: "index_releases_on_play_publish_status"
    t.index ["play_rejected_by_id"], name: "index_releases_on_play_rejected_by_id"
    t.index ["release_type"], name: "index_releases_on_release_type"
    t.index ["release_version", "build_version"], name: "index_releases_on_release_version_and_build_version"
    t.index ["rollout_status"], name: "index_releases_on_rollout_status"
    t.index ["source"], name: "index_releases_on_source"
    t.index ["status"], name: "index_releases_on_status"
    t.index ["version"], name: "index_releases_on_version"
    t.check_constraint "asset_delivery_state IS NULL OR asset_delivery_state::text = 'pending'::text OR asset_delivery_state::text = 'done'::text OR asset_delivery_state::text = 'skipped'::text OR asset_delivery_state::text = 'failed'::text", name: "releases_asset_delivery_state_known"
    t.check_constraint "ci_compile_state IS NULL OR ci_compile_state::text = 'queued'::text OR ci_compile_state::text = 'dispatched'::text OR ci_compile_state::text = 'done'::text OR ci_compile_state::text = 'failed'::text", name: "releases_ci_compile_state_known"
    t.check_constraint "rollout_percentage >= 0 AND rollout_percentage <= 100", name: "releases_rollout_percentage_range"
    t.check_constraint "status::text = 'available'::text OR status::text = 'held'::text OR status::text = 'halted'::text OR status::text = 'pulled'::text", name: "releases_status_known"
  end

  create_table "schemes", force: :cascade do |t|
    t.bigint "app_id"
    t.string "name", null: false
    t.boolean "new_build_callout", default: true
    t.integer "retained_builds", default: 0, null: false
    t.index ["app_id"], name: "index_schemes_on_app_id"
    t.index ["name"], name: "index_schemes_on_name"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.string "var", null: false
    t.index ["var"], name: "index_settings_on_var", unique: true
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", null: false
    t.datetime "created_at", null: false
    t.binary "key", null: false
    t.bigint "key_hash", null: false
    t.binary "value", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "sponsored_slots", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.datetime "ends_at", null: false
    t.datetime "starts_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id", "starts_at"], name: "index_sponsored_slots_on_app_id_and_starts_at"
    t.index ["app_id"], name: "index_sponsored_slots_on_app_id"
  end

  create_table "tenant_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", default: "member", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["tenant_id"], name: "index_tenant_memberships_on_tenant_id"
    t.index ["user_id", "tenant_id"], name: "index_tenant_memberships_on_user_id_and_tenant_id", unique: true
    t.check_constraint "role::text = 'member'::text OR role::text = 'owner'::text", name: "tenant_memberships_role_known"
  end

  create_table "tenant_signing_keys", force: :cascade do |t|
    t.datetime "activated_at"
    t.datetime "created_at", null: false
    t.string "key_id", null: false
    t.datetime "last_signed_at"
    t.text "private_key_pem"
    t.string "public_key", null: false
    t.string "purpose", default: "catalog_index", null: false
    t.datetime "retired_at"
    t.integer "sequence", default: 0, null: false
    t.string "status", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["public_key"], name: "index_tenant_signing_keys_on_public_key", unique: true
    t.index ["tenant_id", "purpose"], name: "index_tenant_signing_keys_one_active", unique: true, where: "((status)::text = 'active'::text)"
    t.index ["tenant_id", "purpose"], name: "index_tenant_signing_keys_one_pending", unique: true, where: "((status)::text = 'pending'::text)"
    t.index ["tenant_id", "purpose"], name: "index_tenant_signing_keys_one_retiring", unique: true, where: "((status)::text = 'retiring'::text)"
    t.index ["tenant_id"], name: "index_tenant_signing_keys_on_tenant_id"
    t.check_constraint "purpose::text = 'catalog_index'::text", name: "tenant_signing_keys_purpose_known"
    t.check_constraint "status::text = 'pending'::text OR status::text = 'active'::text OR status::text = 'retiring'::text OR status::text = 'retired'::text", name: "tenant_signing_keys_status_known"
    t.check_constraint "status::text = 'retired'::text OR private_key_pem IS NOT NULL", name: "tenant_signing_keys_private_key_unless_retired"
  end

  create_table "tenants", force: :cascade do |t|
    t.string "catalog_index_base_url"
    t.string "cdn_base", null: false
    t.datetime "created_at", null: false
    t.datetime "dirty_at"
    t.string "display_name", null: false
    t.jsonb "domains", default: [], null: false
    t.string "logo_sha256"
    t.string "logo_url"
    t.bigint "parent_tenant_id"
    t.string "primary_color_hex", null: false
    t.string "tenant_id", limit: 63, null: false
    t.datetime "updated_at", null: false
    t.index ["parent_tenant_id"], name: "index_tenants_on_parent_tenant_id"
    t.index ["tenant_id"], name: "index_tenants_on_tenant_id", unique: true
    t.check_constraint "jsonb_typeof(domains) = 'array'::text", name: "tenants_domains_is_array"
    t.check_constraint "parent_tenant_id IS NULL OR parent_tenant_id <> id", name: "tenants_parent_not_self"
    t.check_constraint "tenant_id::text ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'::text AND tenant_id::text <> 'default'::text", name: "tenants_tenant_id_format"
  end

  create_table "user_providers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "expires"
    t.integer "expires_at"
    t.string "name"
    t.string "refresh_token"
    t.string "token"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["name", "uid"], name: "index_user_providers_on_name_and_uid"
    t.index ["user_id"], name: "index_user_providers_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "appearance", default: "auto", null: false
    t.datetime "confirmation_sent_at", precision: nil
    t.string "confirmation_token"
    t.datetime "confirmed_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at", precision: nil
    t.string "current_sign_in_ip"
    t.string "dark_theme", default: "dark"
    t.string "email", default: "", null: false
    t.boolean "email_campaigns", default: true, null: false
    t.boolean "email_deploys", default: true, null: false
    t.boolean "email_notices", default: true, null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "last_sign_in_at", precision: nil
    t.string "last_sign_in_ip"
    t.string "light_theme", default: "light"
    t.string "locale", default: "zh-CN", null: false
    t.datetime "locked_at", precision: nil
    t.datetime "remember_created_at", precision: nil
    t.datetime "reset_password_sent_at", precision: nil
    t.string "reset_password_token"
    t.integer "role", null: false
    t.integer "sign_in_count", default: 0, null: false
    t.string "timezone", default: "Asia/Shanghai", null: false
    t.string "token", default: "", null: false
    t.string "unconfirmed_email"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.string "username"
  end

  create_table "web_hooks", force: :cascade do |t|
    t.text "body"
    t.integer "changelog_events", limit: 2
    t.bigint "channel_id"
    t.datetime "created_at", null: false
    t.integer "download_events", limit: 2
    t.text "signing_secret"
    t.datetime "signing_secret_set_at"
    t.integer "upload_events", limit: 2
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["channel_id"], name: "index_web_hooks_on_channel_id"
    t.index ["url"], name: "index_web_hooks_on_url"
  end

  add_foreign_key "android_package_registrations", "apps", on_delete: :nullify
  add_foreign_key "app_api_tokens", "apps", on_delete: :cascade
  add_foreign_key "app_api_tokens", "users", column: "created_by_id", on_delete: :nullify
  add_foreign_key "app_maintenance_billings", "apps"
  add_foreign_key "app_maintenance_billings", "users"
  add_foreign_key "apple_teams", "apple_keys", on_delete: :cascade
  add_foreign_key "apps", "publisher_profiles", on_delete: :nullify
  add_foreign_key "apps", "tenants"
  add_foreign_key "channels", "schemes", on_delete: :cascade
  add_foreign_key "collection_apps", "apps"
  add_foreign_key "collection_apps", "collections"
  add_foreign_key "collections", "tenants"
  add_foreign_key "debug_file_metadata", "debug_files"
  add_foreign_key "debug_files", "apps", on_delete: :cascade
  add_foreign_key "listing_edits", "apps", on_delete: :cascade
  add_foreign_key "listing_edits", "users", column: "editor_id", on_delete: :nullify
  add_foreign_key "listing_graphics", "apps", on_delete: :cascade
  add_foreign_key "metadata", "releases", on_delete: :cascade
  add_foreign_key "metadata", "users", on_delete: :cascade
  add_foreign_key "migrated_comments", "apps", on_delete: :cascade
  add_foreign_key "migrated_comments", "users", column: "recorded_by_id", on_delete: :nullify
  add_foreign_key "payments", "apps"
  add_foreign_key "payments", "users"
  add_foreign_key "payouts", "publisher_profiles"
  add_foreign_key "payouts", "users"
  add_foreign_key "publisher_profiles", "users", on_delete: :cascade
  add_foreign_key "release_uploads", "channels", on_delete: :cascade
  add_foreign_key "release_uploads", "releases", on_delete: :nullify
  add_foreign_key "release_uploads", "users", on_delete: :nullify
  add_foreign_key "releases", "channels", on_delete: :cascade
  add_foreign_key "releases", "users", column: "play_approved_by_id"
  add_foreign_key "releases", "users", column: "play_rejected_by_id"
  add_foreign_key "schemes", "apps", on_delete: :cascade
  add_foreign_key "sponsored_slots", "apps"
  add_foreign_key "tenant_memberships", "tenants"
  add_foreign_key "tenant_memberships", "users"
  add_foreign_key "tenant_signing_keys", "tenants"
  add_foreign_key "tenants", "tenants", column: "parent_tenant_id"
  add_foreign_key "user_providers", "users", on_delete: :cascade
  add_foreign_key "web_hooks", "channels", on_delete: :cascade
end
