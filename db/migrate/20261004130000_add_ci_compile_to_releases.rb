# frozen_string_literal: true

# Task 40a: the state of a release's CI compile (Zealot stops compiling, splitting, signing and
# compressing release files itself; GitHub Actions in the storage repo does it and calls back).
# Additive and unused until 40b dispatches: `ci_compile_state` is NULL for every existing release,
# which means "never sent to CI" (the Ruby compile in AnthropicAssetDeliveryJob still owns those).
#
#   queued      Zealot decided to send the release to CI (set by 40b)
#   dispatched  the workflow_dispatch call to the storage repo succeeded (set by 40b)
#   done        CI called back with a result Zealot verified (set by the 40a callback)
#   failed      the dispatch or the CI run failed, or the callback failed verification; the reason is
#               in `ci_compile_error`
#
# The result columns hold what CI built: the signed universal APK that is served for an AAB (its
# SHA-256 and size are what the catalog index must carry, see 40e). The compressed split set reuses
# the existing `compressed_apks_storage_key` / `compressed_size` / `brotli_compressed` columns.
class AddCiCompileToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :ci_compile_state, :string
    add_column :releases, :ci_compile_error, :text
    add_column :releases, :ci_compile_finished_at, :datetime
    add_column :releases, :universal_apk_storage_key, :string
    add_column :releases, :universal_apk_sha256, :string
    add_column :releases, :universal_apk_size, :bigint

    add_check_constraint :releases,
                         "ci_compile_state IS NULL OR ci_compile_state = 'queued' OR " \
                         "ci_compile_state = 'dispatched' OR ci_compile_state = 'done' OR " \
                         "ci_compile_state = 'failed'",
                         name: 'releases_ci_compile_state_known'

    add_index :releases, :ci_compile_state
  end
end
