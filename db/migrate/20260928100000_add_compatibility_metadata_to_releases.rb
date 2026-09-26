# frozen_string_literal: true

# Task 29c: the `compatibility` block docs/catalog_index_v2.md/.schema.json
# already reserve on every version entry (29a) and CatalogIndex::Serializer
# already emits at its documented empty default (29b) -- this is the slice
# that actually fills it in, for Android releases, from the uploaded APK.
#
# Column names deliberately match AppInfo::APK's own reader methods
# (min_sdk_version/target_sdk_version, see app/models/concerns/
# release_parser.rb) rather than the schema's shorter min_sdk/target_sdk --
# CatalogIndex::Serializer is what translates between the two, same pattern
# as size_bytes <- original_size already used. abis/screen_densities/
# required_features/permissions are jsonb arrays with default [], matching
# this codebase's existing convention for that shape (see the orphaned
# `metadata` table's activities/features/native_codes/permissions/services/
# url_schemes columns -- that table has no ActiveRecord model or code
# referencing it anywhere in this app today, so it's not reused here, but
# its column style is worth matching for consistency).
#
# iOS/other-platform releases simply never populate these (left at their
# column defaults, same "empty, not invented" rule 29a/29b already follow) --
# nothing in the v2 schema requires a non-Android release to carry them.
class AddCompatibilityMetadataToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :min_sdk_version, :integer
    add_column :releases, :target_sdk_version, :integer
    add_column :releases, :abis, :jsonb, default: [], null: false
    add_column :releases, :screen_densities, :jsonb, default: [], null: false
    add_column :releases, :required_features, :jsonb, default: [], null: false
    add_column :releases, :permissions, :jsonb, default: [], null: false
  end
end
