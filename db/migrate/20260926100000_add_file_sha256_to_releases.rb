# frozen_string_literal: true

# Task 27b-i: persist each release's primary-file SHA-256 once, at
# ReleaseFileMirrorJob time, so it survives Task 19's mirror-then-wipe (the
# local file disappearing once it's safely in ReleaseStorage). Closes the
# "sha256 gap" flagged when Task 27a shipped -- CatalogIndex::Serializer
# previously could only hash the file while it happened to still be on
# local disk, which is `null` for most releases in production. See
# docs/catalog_index_v1.md's "The sha256 gap" section for the full context.
#
# Deliberately its own column, not reused from `signing_key_checksum`:
# that column hashes the *signing keystore* (SHA-1), not the release
# binary, and is a different concept entirely.
class AddFileSha256ToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :file_sha256, :string
  end
end
