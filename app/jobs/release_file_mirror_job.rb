# frozen_string_literal: true

require 'digest'

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
# Task 27b-i: also hashes the primary file (SHA-256) and persists it to
# `Release#file_sha256` while it's still guaranteed to be on local disk --
# this is the one place in the pipeline that's true for every release,
# mirrored-to-remote-storage or not. See CatalogIndex::Serializer#sha256_for,
# which prefers this persisted value and only falls back to hashing the
# local file live (the old, gap-prone path) when it's blank -- e.g. for
# releases created before this migration, until `.backfill` catches them up.
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

    record_sha256(release)

    return unless ReleaseStorage.remote?

    mirror(release, :file_storage_key, release.file&.path)
    mirror(release, :patched_file_storage_key, release.patched_file_path)
  rescue ReleaseStorage::ConfigurationError => e
    logger.error("[ReleaseFileMirrorJob] release #{release_id}: #{e.message}")
  end

  private

  # Deliberately outside the `ReleaseStorage.remote?` early-return above:
  # the sha256 gap exists on any host with an ephemeral disk regardless of
  # which storage adapter is configured, and hashing needs nothing from
  # ReleaseStorage -- it only reads the file this job already has local
  # access to, before anything else in the pipeline has a chance to wipe it.
  def record_sha256(release)
    return if release[:file_sha256].present?

    path = release.file&.path
    return unless path && File.file?(path)

    release.update_columns(file_sha256: Digest::SHA256.file(path).hexdigest)
  rescue Errno::ENOENT, IOError => e
    logger.warn("[ReleaseFileMirrorJob] release #{release.id}: could not hash #{File.basename(path.to_s)}: #{e.message}")
  end

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
