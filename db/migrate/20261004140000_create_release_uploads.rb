# frozen_string_literal: true

# Task 40h-a: the staging record of the decided Task 40 flow (R2 staging, two-phase ingest). One row per
# upload that has been asked for, BEFORE any `Release` exists: the client sends the bytes straight to an R2
# staging bucket through a presigned URL, CI reads the file, and only then is the real `Release` created
# (slice 40i-b). Nothing reads or writes this table yet (the session and finalize doors are 40h-b), so this
# migration changes no behaviour.
#
# `state` vocabulary lives in `ReleaseUpload::STATES`, not in SQL (the same split
# `AndroidPackageRegistration` makes): awaiting_bytes, uploaded, processing, failed, expired, done.
# `declared_size` is what the client said it will send; the finalize step compares it with what storage
# reports. `staging_key` is the object key in the staging bucket, chosen by Zealot, never by the client.
# `form_options` holds what the upload form and the API carry today (hold, play_store_target, changelog,
# branch, commit, CI URL, custom fields, source); nothing in it is trusted until the release is created.
#
# `release_id` is the unique reference from the upload to the release CI's callback creates: one upload can
# never produce two releases, which is what makes the callback idempotent. It is nullable with ON DELETE
# SET NULL so deleting a release does not delete the record of how it arrived.
class CreateReleaseUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :release_uploads do |t|
      t.references :channel, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :release, foreign_key: { on_delete: :nullify }, index: { unique: true }

      t.string :state, null: false, default: 'awaiting_bytes'
      t.string :filename, null: false
      t.string :content_type
      t.bigint :declared_size, null: false
      t.bigint :uploaded_size
      t.string :etag
      t.string :staging_key
      t.string :multipart_upload_id
      t.jsonb :form_options, null: false, default: {}
      t.text :error
      t.datetime :expires_at
      t.datetime :uploaded_at

      t.timestamps
    end

    add_index :release_uploads, :staging_key, unique: true
    add_index :release_uploads, %i[state expires_at]
    add_check_constraint :release_uploads, 'declared_size > 0', name: 'release_uploads_declared_size_positive'
  end
end
