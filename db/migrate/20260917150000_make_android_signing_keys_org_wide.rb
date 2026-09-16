# frozen_string_literal: true

# Reverses the per-App scoping added in 20260917140000_create_android_signing_keys.rb.
# Operator decision (see handover.md task #5): every AAB signed by this
# pipeline comes from this one organization, so one shared keystore signs
# everything rather than one keystore per App. Singleton-ness is enforced at
# the application level (AndroidSigningKey#only_one_record, validate on
# create) the same way this codebase enforces other app-level singletons —
# there is deliberately no DB-level "at most one row" constraint here.
class MakeAndroidSigningKeysOrgWide < ActiveRecord::Migration[7.1]
  def up
    remove_reference :android_signing_keys, :app, foreign_key: true, index: { unique: true }
  end

  def down
    add_reference :android_signing_keys, :app, null: false, foreign_key: true, index: { unique: true }
  end
end
