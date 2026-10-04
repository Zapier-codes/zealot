# frozen_string_literal: true

# Task 40f: once CI has compiled a release, deletes the uploaded `.aab` from this host's local disk.
#
# The bundle is the one big file Zealot kept on `public/uploads` after the upload: CI compiled from the copy
# in storage, and since 40e the release is served as its signed universal APK from storage. Keeping the
# bundle only wastes disk on a host with a small one (Render free). This frees DISK, not memory: the memory
# kills the Task 40 entry describes came from the compile, and moving the compile to CI is what fixes them.
#
# Enqueued by `Api::CiCompileController` when it records `done`. The file is deleted only when ALL of these
# hold, checked in this order (cheap local checks first, the one network call last):
#
#   0. a local `.aab` is on disk at all (else there is nothing to do, and no storage call is made)
#   1. storage is remote (`ReleaseStorage.remote?`): on the `local` adapter the local file IS the stored copy
#   2. the compile is done AND its universal APK is fully recorded (`Release#serves_universal_apk?`), so the
#      release is installable without the bundle
#   3. the bundle's SHA-256 is recorded (`file_sha256`, written by `ReleaseFileMirrorJob` while the file was
#      still on disk), so the catalog index and the integrity checks do not need the local file
#   4. storage confirms it holds the bundle: `file_storage_key` is set, names the same file, and
#      `ReleaseStorage#exist?` says the object is there
#
# Only the bundle goes. The icon, the patched file and every database column stay as they are: the row keeps
# its `file` column and `file_storage_key`, and `Release#file?`, `ReleaseDownload` and
# `ReleaseStorage#with_local_file` already fall back to storage when the local file is missing (40e, 19d).
# Any doubt means the file is kept and the reason is logged; a later call (the callback, or `.backfill`)
# tries again. Never raises for a storage problem: eviction is housekeeping, not part of a release's result.
#
#   rails runner 'ReleaseLocalEvictionJob.backfill'   # re-check every release whose compile is done
#
# Not verified: no Ruby runtime run in the sandbox this was written in; nothing was executed.
class ReleaseLocalEvictionJob < ApplicationJob
  queue_as :default

  def self.backfill
    Release.where(ci_compile_state: 'done').find_each { |release| perform_later(release.id) }
  end

  # @return [Symbol, nil] :evicted, or the reason the local file was kept (nil when the release is gone)
  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release

    path = local_bundle_path(release)
    return keep(release, :nothing_to_evict) unless path

    reason = refusal(release, path)
    return keep(release, reason) if reason

    File.delete(path)
    logger.info("[ReleaseLocalEvictionJob] release #{release.id}: deleted local #{File.basename(path)}")
    :evicted
  rescue Errno::ENOENT
    :nothing_to_evict
  rescue ReleaseStorage::ConfigurationError, ReleaseStorage::StorageError => e
    logger.error("[ReleaseLocalEvictionJob] release #{release_id}: kept the local file, storage check failed: " \
                 "#{e.message}")
    :storage_unavailable
  rescue SystemCallError => e
    logger.error("[ReleaseLocalEvictionJob] release #{release_id}: could not delete the local file: #{e.message}")
    :delete_failed
  end

  private

  # The release's own uploaded bundle, if it is still on this disk. An APK (or anything else) is never touched.
  def local_bundle_path(release)
    path = release.file&.path
    return unless path.to_s.end_with?('.aab') && File.file?(path)

    path
  end

  # @return [Symbol, nil] why the file must stay, or nil when all four checks hold
  def refusal(release, path)
    return :storage_is_local unless ReleaseStorage.remote?
    return :compile_not_done unless release.serves_universal_apk?
    return :sha256_not_recorded if release[:file_sha256].blank?
    return :bundle_not_in_storage unless same_file?(release.file_storage_key, path)

    :bundle_not_in_storage unless ReleaseStorage.new(release).exist?(release.file_storage_key)
  end

  # The mirror keys the object by the local file's name (ReleaseStorage#store_binary), so a key that names
  # anything else is not a copy of this file.
  def same_file?(key, path)
    key.present? && File.basename(key.to_s) == File.basename(path)
  end

  def keep(release, reason)
    logger.info("[ReleaseLocalEvictionJob] release #{release.id}: kept the local file (#{reason})")
    reason
  end
end
