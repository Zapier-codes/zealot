# frozen_string_literal: true

# Task 19c: where a release's uploaded file(s) live in ReleaseStorage once
# mirrored (GitHub Releases / R2). The local copy under public/uploads is
# still written first, but Render's disk is wiped on every deploy, so these
# keys are what downloads fall back to.
class AddFileStorageKeysToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :file_storage_key, :string
    add_column :releases, :patched_file_storage_key, :string
  end
end
