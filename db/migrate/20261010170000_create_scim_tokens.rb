# frozen_string_literal: true

# Z-P18 (SCIM half, Play Console parity): the credential an identity provider's SCIM 2.0 client uses to
# provision and deprovision people in Zealot. See ScimToken for the secret discipline (shared with
# AppApiToken). `tenant_id` is nullable: a platform-scoped token (the default host) has none; a tenant's
# token is scoped to that tenant, so one org's IdP cannot touch another's members. Only the digest is stored.
class CreateScimTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :scim_tokens do |t|
      t.references :tenant, foreign_key: true, null: true, index: true
      t.references :created_by, foreign_key: { to_table: :users }, null: true, index: true
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :last_four, null: false
      t.datetime :expires_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.text :scopes, default: ['provision'], null: false, array: true

      t.timestamps
    end

    add_index :scim_tokens, :token_digest, unique: true
  end
end
