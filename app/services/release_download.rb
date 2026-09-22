# frozen_string_literal: true

# Decides where a release download comes from (Task 19c):
#
#   1. a file that is still on this host's disk (fast, no external call),
#      the patched internal APK first, then the primary file; else
#   2. the copy mirrored to ReleaseStorage (ReleaseFileMirrorJob), as a
#      short-lived signed URL the caller redirects to; else
#   3. nothing.
#
# Order 1 before 2 keeps behaviour identical to before while the local file
# exists; 2 is what keeps downloads working after a redeploy wipes the disk.
# A release with a patched APK (Play-targeted Android) prefers the patched
# copy in both tiers and falls back to the primary file if it is missing.
class ReleaseDownload
  Source = Struct.new(:kind, :path, :url, keyword_init: true)
  MISSING = Source.new(kind: :missing).freeze

  def initialize(release, storage: nil)
    @release = release
    @storage = storage
  end

  # Cheap and offline: is there anything to serve at all?
  def available?
    !local_path.nil? || !remote_key.nil?
  end

  # @return [Source] kind is :file (path), :redirect (url) or :missing
  def resolve
    path = local_path
    return Source.new(kind: :file, path: path) if path

    key = remote_key
    return MISSING unless key

    url = storage.url_for(key)
    url ? Source.new(kind: :redirect, url: url) : MISSING
  rescue ReleaseStorage::ConfigurationError, ReleaseStorage::StorageError => e
    Rails.logger&.error("[ReleaseDownload] release #{@release.id}: #{e.message}")
    MISSING
  end

  private

  def storage
    @storage ||= ReleaseStorage.new(@release)
  end

  def local_path
    patched = @release.patched_file_path
    return patched if patched.present? && File.file?(patched)

    primary = @release.file&.path
    primary if primary.present? && File.file?(primary)
  end

  def remote_key
    primary = @release.file_storage_key.presence
    return primary if @release.patched_file_path.blank?

    @release.patched_file_storage_key.presence || primary
  end
end
