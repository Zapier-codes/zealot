# frozen_string_literal: true

# Z-P13 (Play Console parity, docs/PARITY-KANBAN.md): delta updates, the Zealot "generate" half. Play ships
# a small patch instead of the whole APK; the client applies it and checks the result byte for byte. The
# patch is archive-patcher's File-by-File v1 format (`ArchivePatcher::FileByFile`), produced when a new
# release supersedes the previous one, while both APKs are still on disk.
#
# `delta_patches` is a jsonb array of manifests, one per base version the patch was made from:
#   [{ "from_release_id": 12, "from_version_code": "42", "storage_key": "...", "size": 8123,
#      "sha256": "...", "from_sha256": "...", "to_sha256": "...", "format": "GFbFv1_0", "generated_at": "..." }]
# It is additive to the signed catalog index (the `delta_patches` block on each version), so a reader that
# does not know the key ignores it and no schema_version bump is needed. The client chooses the patch whose
# `from_version_code` equals the installed one; when there is none it downloads the full APK.
class AddDeltaPatchesToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :delta_patches, :jsonb, default: [], null: false
  end
end
