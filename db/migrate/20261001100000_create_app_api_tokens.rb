# frozen_string_literal: true

# Task 34a-1 (Storeapp leaf `f.xiv`): a per-app API token exists as data. Nothing reads or writes
# this table until 34a-2 adds the header-only auth path, so this changes no behaviour.
#
# Only a plain SHA-256 digest of the 256-bit secret is stored (decision 34-1): the digest is the
# lookup key, so it is unique-indexed and deterministic (no salt, no pepper). The secret itself is
# shown once, when it is issued, and is never recoverable. `last_four` is for the token list screen
# (34a-7) only.
#
# `scopes` is a column from day one although only `publish` exists (decision 34-4), so splitting the
# scope later is a code change, not a migration. The vocabulary lives in `AppApiToken::SCOPES`, not
# in SQL, the same split `ListingGraphicRules` makes.
#
# `created_by_id` is nullable with `ON DELETE SET NULL`, on purpose: a token is revoked softly and
# its row is kept so the future audit log (34c) can still name it, so deleting a user must neither
# be blocked by their tokens nor erase them. A live token whose creator is gone authenticates as
# nobody: 34a-2 re-checks the creator on every request and answers 401.
class CreateAppApiTokens < ActiveRecord::Migration[7.1]
  def change
    create_table :app_api_tokens do |t|
      t.references :app, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :last_four, null: false
      t.text :scopes, array: true, null: false, default: ['publish']
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at
      t.timestamps

      t.index :token_digest, unique: true
    end
  end
end
