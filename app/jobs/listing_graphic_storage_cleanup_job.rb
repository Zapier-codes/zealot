# frozen_string_literal: true

# Task 27d-d2-b: deletes a destroyed listing graphic's object from storage. The row is already gone by
# the time this runs (enqueued from ListingGraphic#enqueue_storage_cleanup, an after_destroy_commit
# callback), so it works from the key it was given rather than looking the graphic back up.
#
# Best-effort like ReleaseStorageCleanupJob: a failure is logged, not raised, because the graphic the
# owner asked to delete is gone either way and one orphaned object is a smaller problem than a delete
# that looks like it failed.
#
# Unlike ReleaseStorageCleanupJob this does NOT skip the local adapter. A release's local file belongs
# to CarrierWave, which removes it itself; a graphic has no CarrierWave copy, so the local adapter's
# own file (written by ListingGraphicStorage) is the only one and nothing else would ever delete it.
class ListingGraphicStorageCleanupJob < ApplicationJob
  queue_as :default

  def perform(graphic_id, keys)
    adapter = ReleaseStorage.build_adapter
    keys.compact.uniq.each do |key|
      adapter.delete(key)
    rescue ReleaseStorage::StorageError => e
      logger.error("[ListingGraphicStorageCleanupJob] graphic #{graphic_id} key #{key}: #{e.message}")
    end
  rescue ReleaseStorage::ConfigurationError => e
    logger.error("[ListingGraphicStorageCleanupJob] graphic #{graphic_id}: #{e.message}")
  end
end
