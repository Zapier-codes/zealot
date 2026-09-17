# frozen_string_literal: true

# Task #7: the Google Cloud service-account key used to authenticate calls
# to the Play Developer API (edits/bundles/tracks). Entirely separate
# concern from PlayUploadKey (20260917160000) — this authenticates *API
# calls to Google*, PlayUploadKey signs the *artifact bytes* handed to
# Google. Org-wide singleton for the same reason as AndroidSigningKey /
# PlayUploadKey: every app published through this pipeline belongs to this
# one organization's single Play Console account.
class CreatePlayCredentials < ActiveRecord::Migration[7.1]
  def change
    create_table :play_credentials do |t|
      t.text :service_account_json, null: false
      t.string :service_account_email, null: false
      t.string :project_id
      t.string :checksum, null: false

      t.timestamps
    end

    add_index :play_credentials, :checksum, unique: true
  end
end
