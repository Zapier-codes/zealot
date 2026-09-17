# frozen_string_literal: true

# Task #7: a keystore used ONLY to sign AABs before they're uploaded to
# Google Play, kept deliberately separate from AndroidSigningKey (task
# #5's key for this org's own internal-distribution signing).
#
# Operator decision this session: do not reuse AndroidSigningKey as the
# Play upload key, even though Play App Signing bounds the blast radius of
# an upload-key leak (Google re-signs with the real distribution key it
# holds, so an uploader key alone can't produce an installable forged
# update). Keeping upload-key material for a third-party platform
# (Google) entirely separate from the key this org uses to sign what it
# hands directly to its own users is the industry-standard posture for
# key separation/compartmentalization, independent of what Play's own
# architecture happens to tolerate. Same org-wide-singleton shape as
# AndroidSigningKey (see that model's comments for the general rationale
# for one shared key vs. one per App) — just a different key, for a
# different destination.
class CreatePlayUploadKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :play_upload_keys do |t|
      t.string :filename, null: false
      t.string :key_alias, null: false
      t.string :checksum, null: false
      t.text :keystore, null: false
      t.text :keystore_password, null: false
      t.text :key_password, null: false

      t.timestamps
    end

    add_index :play_upload_keys, :checksum, unique: true
  end
end
