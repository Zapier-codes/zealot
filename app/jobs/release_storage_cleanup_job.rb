# frozen_string_literal: true

# Task 19e: deletes a destroyed release's objects from ReleaseStorage. The
# release row is already gone by the time this runs (enqueued from
# Release#enqueue_storage_cleanup, an after_destroy_commit callback), so it
# works from the keys it was given rather than looking the release back up.
#
# Best-effort like the other storage jobs: a failure is logged, not raised,
# because the release the user asked to delete is already gone either way —
# retrying the whole delete isn't an option, and leaving one orphaned object
# behind is a smaller problem than looking like the delete failed. Does
# nothing on the `local` adapter (its files were removed by CarrierWave, and
# it was never used for pipeline artifacts either).
#
# On the `github` adapter, deleting every key for a release also removes the
# GitHub release and its tag once the last asset is gone (see
# ReleaseStorage::GithubAdapter#delete), so a fully-mirrored release cleans
# up in one shot rather than leaving an empty release behind.
class ReleaseStorageCleanupJob < ApplicationJob
  queue_as :default

  def perform(release_id, keys)
    return unless ReleaseStorage.remote?

    adapter = ReleaseStorage.build_adapter
    keys.compact.uniq.each do |key|
      adapter.delete(key)
    rescue ReleaseStorage::StorageError => e
      logger.error("[ReleaseStorageCleanupJob] release #{release_id} key #{key}: #{e.message}")
    end
  rescue ReleaseStorage::ConfigurationError => e
    logger.error("[ReleaseStorageCleanupJob] release #{release_id}: #{e.message}")
  end
end
