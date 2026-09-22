# frozen_string_literal: true

# Task 19c: copies a release's uploaded file(s) to ReleaseStorage so they
# survive a redeploy of a host with an ephemeral disk (Render Free).
#
# Enqueued by ProxySdkInjectionJob *after* the proxy SDK injector has run,
# because the injector rewrites, renames or adds files under the release's
# directory; mirroring earlier would store the unpatched file. Mirrors up to
# two files: the primary file, and (Play-targeted Android releases) the
# patched internal APK kept next to the clean AAB.
#
# Best-effort like the other pipeline jobs: a failure is logged and leaves the
# storage key blank, so the release simply keeps serving from local disk until
# `ReleaseFileMirrorJob.backfill` (or a re-run) mirrors it. It never blocks or
# fails an upload. Does nothing on the `local` adapter.
#
#   rails runner 'ReleaseFileMirrorJob.backfill'   # mirror every release not yet stored
class ReleaseFileMirrorJob < ApplicationJob
  queue_as :default

  def self.backfill
    Release.where(file_storage_key: nil).find_each { |release| perform_later(release.id) }
  end

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release
    return unless ReleaseStorage.remote?

    mirror(release, :file_storage_key, release.file&.path)
    mirror(release, :patched_file_storage_key, release.patched_file_path)
  rescue ReleaseStorage::ConfigurationError => e
    logger.error("[ReleaseFileMirrorJob] release #{release_id}: #{e.message}")
  end

  private

  def mirror(release, column, local_path)
    return if local_path.blank?
    return if release[column].present?

    unless File.file?(local_path)
      logger.warn("[ReleaseFileMirrorJob] release #{release.id}: #{File.basename(local_path)} is not on disk, skipping")
      return
    end

    key = ReleaseStorage.new(release).store_binary(local_path)
    release.update_columns(column => key)
  rescue ReleaseStorage::StorageError => e
    logger.error("[ReleaseFileMirrorJob] release #{release.id} #{column}: #{e.message}")
  end
end
