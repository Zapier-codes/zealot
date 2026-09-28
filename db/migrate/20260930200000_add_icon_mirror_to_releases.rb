# frozen_string_literal: true

# Task 27d-a: a release's icon lives on CarrierWave's local disk (public/uploads), which a host with an
# ephemeral disk (Render) loses on redeploy. Same fix 27b-i and Task 19c applied to the release file: persist
# the icon's SHA-256 once, while the file is still local, and mirror the file to ReleaseStorage. Both columns
# are nullable and nothing reads them yet (27d-c makes the index read them), so this changes no behaviour.
class AddIconMirrorToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :icon_sha256, :string
    add_column :releases, :icon_storage_key, :string
  end
end
