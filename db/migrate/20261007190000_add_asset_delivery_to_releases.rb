# frozen_string_literal: true

# Task 30 (D-Store leaf 7.a.vi.zi): record the compile outcome on the release, so "still running" and
# "failed" stop looking the same. `AnthropicAssetDeliveryJob` is best-effort and returns on every failure
# path, and `releases.signed` only turns true on success, so before this column a failed or skipped compile
# left no trace beyond a log line.
#
# `asset_delivery_state` is one of pending/done/skipped/failed (NULL until a job touches the release, which
# is how a release that never reached the job is told apart from one that did). `asset_delivery_error` is a
# short, safe reason (never a path or a secret). The check constraint mirrors the enum, the same
# belt-and-braces pattern `releases_ci_compile_state_known` already uses.
class AddAssetDeliveryToReleases < ActiveRecord::Migration[8.1]
  def change
    add_column :releases, :asset_delivery_state, :string
    add_column :releases, :asset_delivery_error, :text
    add_column :releases, :asset_delivery_state_at, :datetime

    add_check_constraint :releases,
      "asset_delivery_state IS NULL OR asset_delivery_state::text IN ('pending', 'done', 'skipped', 'failed')",
      name: "releases_asset_delivery_state_known"
  end
end
