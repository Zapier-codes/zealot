# frozen_string_literal: true

# Task 27b-ii: the singleton Ed25519 key that signs the catalog index.
# private_key_pem is encrypted by Active Record Encryption (model level);
# public_key (base64 raw 32 bytes), key_id and last_signed_at are not secret.
class CreateCatalogIndexSigningKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :catalog_index_signing_keys do |t|
      t.text :private_key_pem, null: false
      t.string :public_key, null: false
      t.string :key_id, null: false
      t.datetime :last_signed_at
      t.timestamps
    end

    add_index :catalog_index_signing_keys, :public_key, unique: true
  end
end
