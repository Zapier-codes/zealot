# frozen_string_literal: true

# Task 36b-3: one row per Android package name Zealot has tried to register with Google's Android
# Developer Console, under the organisation's single verified developer account. Nothing reads or
# writes this table until `GoogleAdc::Registrar` (36b-5), so this migration changes no behaviour.
#
# `package_name` is unique and is the key, not `app_id`: two apps could in principle share a name,
# and Google sees only the name. `app_id` and `tenant_id` record where the name came from, so a
# later transfer to a tenant can be done per package (decision 36-1). `app_id` is nullable with
# ON DELETE SET NULL on purpose: deleting an app must not erase the record that the organisation
# registered that name. `tenant_id` is a plain informational copy (no foreign key): it must survive
# the tenant being removed, for the same reason.
#
# `state` is Zealot's own summary (the vocabulary lives in `AndroidPackageRegistration::STATES`, not
# in SQL, the same split `ListingGraphicRules` makes). `google_package_state` and `key_state` hold
# Google's own words from the last read, unprocessed.
class CreateAndroidPackageRegistrations < ActiveRecord::Migration[7.1]
  def change
    create_table :android_package_registrations do |t|
      t.string :package_name, null: false
      t.references :app, null: true, foreign_key: { on_delete: :nullify }
      t.bigint :tenant_id
      t.string :state, null: false, default: 'pending'
      t.string :developer_account
      t.string :google_package_state
      t.string :key_state
      t.string :key_fingerprint_sha256
      t.string :policy_strategy
      t.text :last_error
      t.datetime :last_checked_at

      t.timestamps
    end

    add_index :android_package_registrations, :package_name, unique: true
  end
end
