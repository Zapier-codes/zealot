# frozen_string_literal: true

require 'digest'
require 'tmpdir'
require_relative 'file_by_file'

module ArchivePatcher
  # Z-P13: produce the File-by-File v1 delta a client needs to update from one release to a newer one. The
  # delta itself is `ArchivePatcher::FileByFile`; this class only decides *when* a patch can be made (both
  # APKs must really be bytes we can read), *what* bytes to diff, stores the patch through ReleaseStorage,
  # and answers with the manifest the signed index will carry.
  #
  # It is the "generate" half only: nothing here applies a patch on a device (that is Storeapp's half) and
  # nothing here changes the release lifecycle. A patch is refused, never guessed, whenever an input is
  # missing -- a release served from storage but with no local copy, a CI-built release whose universal APK
  # is not on disk, a pair with the same bytes, or a pair whose deflate settings could not be reproduced.
  #
  #   result = ArchivePatcher::Generator.new(new_release).generate_from(old_release)
  #   # => nil, or { from_release_id:, from_version_code:, storage_key:, size:, sha256:, ... }
  #
  # Off unless DELTA_PATCHING is enabled (config.x.anthropic.delta_patching_enabled / ENABLE_DELTA_PATCHING),
  # so an un-set deployment produces nothing and serves the full APK, exactly as before.
  class Generator
    class Refused < StandardError; end

    # Hard ceiling on the *new* archive we will read into memory to diff. A patch larger than this is not
    # worth the memory; the client keeps downloading the full APK, which is the honest fallback.
    MAX_ARCHIVE_BYTES = 300 * 1024 * 1024

    def initialize(new_release, storage: nil)
      @new_release = new_release
      @storage = storage || ReleaseStorage.new(new_release)
    end

    def self.enabled?
      Rails.application.config.x.anthropic.delta_patching_enabled
    rescue StandardError
      false
    end

    # Make a patch from `old_release` to this release. Returns the manifest Hash (also appended to
    # `release.delta_patches`) or nil when there is nothing to do / it cannot be done.
    # @raise [Refused] only for a pair that should never be attempted (the caller logs it)
    def generate_from(old_release)
      return nil unless self.class.enabled?
      return nil if old_release.nil? || old_release.id == @new_release.id

      old_bytes = read_archive(old_release)
      new_bytes = read_archive(@new_release)
      return nil if old_bytes.nil? || new_bytes.nil?
      return nil if old_bytes == new_bytes

      result = FileByFile.generate(old_bytes, new_bytes)
      key = @storage.store_delta_patch_bytes(result.patch, from_release: old_release,
                                             from_version_code: old_release.respond_to?(:build_version) ? old_release.build_version : nil)
      manifest = manifest_for(old_release, result, key)
      record(manifest)
      manifest
    rescue ArchivePatcher::Error, ReleaseStorage::StorageError => e
      Rails.logger&.warn("[ArchivePatcher::Generator] release #{@new_release.id}: #{e.class}: #{e.message}")
      nil
    end

    private

    # The bytes to diff for a release: its local file, or (the steady state) the file fetched back out of
    # ReleaseStorage. A CI-built release is served only as its universal APK, so that is what a client has
    # installed and what the patch must be made against.
    def read_archive(release)
      key = archive_key(release)
      return nil if key.blank?

      local = release.file&.path
      if local.present? && File.file?(local)
        bytes = File.binread(local)
        return bytes.bytesize <= MAX_ARCHIVE_BYTES ? bytes : nil
      end

      Dir.mktmpdir("delta-#{release.id}-") do |dir|
        fetched = @storage.fetch(key, to: File.join(dir, File.basename(key)))
        return nil unless fetched

        bytes = File.binread(fetched)
        return bytes.bytesize <= MAX_ARCHIVE_BYTES ? bytes : nil
      end
    rescue ReleaseStorage::StorageError => e
      Rails.logger&.warn("[ArchivePatcher::Generator] release #{release.id}: #{e.class}: #{e.message}")
      nil
    end

    # The storage key that holds the installed APK. A CI-built release's universal APK wins; otherwise the
    # served file (via ReleaseDownload, so patched/primary is chosen the same way a download is).
    def archive_key(release)
      return release.universal_apk_storage_key if release.respond_to?(:serves_universal_apk?) && release.serves_universal_apk?

      ReleaseDownload.new(release).served_storage_key
    rescue StandardError
      release.respond_to?(:file_storage_key) ? release.file_storage_key : nil
    end

    def manifest_for(old_release, result, key)
      {
        'from_release_id' => old_release.id,
        'from_version_code' => old_release.respond_to?(:build_version) ? old_release.build_version.to_s : nil,
        'storage_key' => key,
        'size' => result.patch.bytesize,
        'sha256' => Digest::SHA256.hexdigest(result.patch),
        'from_sha256' => result.old_sha256,
        'to_sha256' => result.new_sha256,
        'from_size' => result.old_size,
        'to_size' => result.new_size,
        'format' => FileByFile::MAGIC,
        'generated_at' => Time.current.utc.iso8601
      }
    end

    # Append the manifest, replacing any earlier patch from the same base version. A normal `update!` (not
    # `update_column`) so the release's own catalog-index callback republishes and the new `delta_patches`
    # reach readers; `delta_patches` is in CATALOG_INDEX_RELEASE_FIELDS for exactly this reason.
    def record(manifest)
      patches = @new_release.delta_patches
      patches = [] unless patches.is_a?(Array)
      kept = patches.reject { |p| p.is_a?(Hash) && p['from_release_id'] == manifest['from_release_id'] }
      @new_release.update!(delta_patches: kept + [manifest])
    end
  end
end
