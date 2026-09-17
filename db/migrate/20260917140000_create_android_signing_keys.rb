# frozen_string_literal: true

class CreateAndroidSigningKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :android_signing_keys do |t|
      t.references :app, null: false, foreign_key: true, index: { unique: true }
      t.string :filename, null: false
      t.string :key_alias, null: false
      t.string :checksum, null: false
      # `text`, not `binary`/`string`: Active Record Encryption (see
      # config/initializers/active_record_encryption.rb) transparently
      # encrypts these three columns in place via `encrypts` on the model —
      # there is no separate ciphertext column, this column IS the
      # ciphertext at rest and the plaintext in memory.
      t.text :keystore, null: false
      t.text :keystore_password, null: false
      t.text :key_password, null: false

      t.timestamps
    end

    add_index :android_signing_keys, :checksum, unique: true
  end
end
