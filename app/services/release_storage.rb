# frozen_string_literal: true

# Storage abstraction for release files: the artifacts the Play Asset
# Delivery / Brotli / delta pipeline produces (Brotli-compressed APK sets,
# delta patches, asset pack splits), and, since Task 19c, a mirror of the
# uploaded AAB/APK/IPA itself.
#
# CarrierWave still owns the *local* copy of the uploaded file (it is written
# to public/uploads first, then mirrored here by ReleaseFileMirrorJob). Hosts
# with an ephemeral disk lose the local copy on redeploy, so downloads fall
# back to the mirrored copy (see ReleaseDownload). The storage target can be
# local disk in development, Cloudflare R2 (S3-compatible) or GitHub Release
# assets in production, without the calling code caring which.
#
# Usage:
#   storage = ReleaseStorage.new(release)
#   storage.store_binary(local_path)            # => storage key (uploaded file)
#   storage.store_icon(local_path)              # => storage key (release icon, Task 27d-a)
#   storage.store_compressed_apks(local_path)   # => storage key
#   storage.store_delta_patch(local_path, from_release: other_release)
#   storage.fetch(key, to: local_path)           # download to a local path
#   storage.url_for(key)                         # public/presigned URL, or nil
#   storage.delete(key)
#
# The adapter is chosen by RELEASE_STORAGE_ADAPTER: "local", "r2" or "github"
# (GitHub Release assets in a dedicated private storage repo, Task 19).
# Outside production an unset value means "local" so dev setups keep working
# untouched. In production it is an error: hosts like Render have an ephemeral
# disk, so silently falling back to "local" loses every stored file on the next
# deploy.
class ReleaseStorage
  class ConfigurationError < StandardError; end
  class StorageError < StandardError; end
  # Raised by with_local_file when a release has neither a local copy nor a
  # storage key/object to fall back to.
  class MissingFileError < StorageError; end

  ADAPTERS = %w[local r2 github].freeze

  def self.adapter_name
    configured = ENV['RELEASE_STORAGE_ADAPTER'].to_s.strip.downcase
    return configured unless configured.empty?

    if Rails.env.production?
      raise ConfigurationError, 'RELEASE_STORAGE_ADAPTER is not set. In production it must be one of ' \
                                "#{ADAPTERS.join(', ')}; falling back to local disk would lose files on redeploy."
    end

    'local'
  end

  def self.build_adapter
    case adapter_name
    when 'local' then ReleaseStorage::LocalAdapter.new
    when 'r2' then ReleaseStorage::R2Adapter.new
    when 'github' then ReleaseStorage::GithubAdapter.new
    else
      raise ConfigurationError, "Unknown RELEASE_STORAGE_ADAPTER: #{adapter_name.inspect}. " \
                                 "Expected one of #{ADAPTERS.join(', ')}."
    end
  end

  # True when files are kept somewhere other than this host's own disk. The
  # local adapter mirrors onto the very path CarrierWave already wrote to, so
  # there is nothing to mirror.
  def self.remote?
    adapter_name != 'local'
  end

  attr_reader :release, :adapter

  def initialize(release, adapter: self.class.build_adapter)
    @release = release
    @adapter = adapter
  end

  # Mirrors one of the release's own uploaded files (the primary file, or the
  # patched internal APK next to it). The key equals the file's path under
  # public/, i.e. CarrierWave's store_dir plus the file name.
  #
  # @return [String] the storage key the file was stored under
  def store_binary(local_path)
    key = binary_key(File.basename(local_path))
    adapter.put(key, local_path)
    key
  end

  # Task 27d-a: mirrors the release's icon (CarrierWave's `icons/` directory, next to the binary).
  #
  # @return [String] the storage key the icon was stored under
  def store_icon(local_path)
    key = icon_key(File.basename(local_path))
    adapter.put(key, local_path)
    key
  end

  # @return [String] the storage key the compressed .apks was stored under
  def store_compressed_apks(local_path)
    key = artifact_key("release.apks.br")
    adapter.put(key, local_path, content_encoding: 'br')
    key
  end

  # @return [String] the storage key the delta patch was stored under
  def store_delta_patch(local_path, from_release:)
    key = artifact_key("delta-from-#{from_release.id}.bspatch")
    adapter.put(key, local_path)
    key
  end

  # @return [String] the storage key an asset pack split was stored under
  def store_asset_pack(local_path, pack_name:)
    key = artifact_key("packs/#{pack_name}.apks")
    adapter.put(key, local_path)
    key
  end

  # Downloads `key` to `to` (a local path) and returns `to`, or nil if the
  # key doesn't exist in this adapter.
  def fetch(key, to:)
    adapter.get(key, to)
  end

  # Best-effort URL for serving the artifact directly (e.g. a presigned R2
  # URL). Returns nil for adapters that can't produce one (local), in which
  # case the caller should fall back to `fetch` + `send_file`.
  def url_for(key, expires_in: 3600)
    adapter.url_for(key, expires_in: expires_in)
  end

  def delete(key)
    adapter.delete(key)
  end

  def exist?(key)
    adapter.exist?(key)
  end

  # Task 45e: how many times the host counted this file as downloaded (GitHub adapter only; nil elsewhere or when
  # the file is missing).
  def download_count(key)
    adapter.respond_to?(:asset_download_count) ? adapter.asset_download_count(key) : nil
  end

  # Task 44f: renames a stored file in place (no download, no re-upload where the adapter can avoid it).
  #
  # @return [Symbol] `:renamed`, `:already`, `:same` or `:missing` (see the adapters)
  def rename(from_key, to_key)
    adapter.rename(from_key, to_key)
  end

  # Task 40i-b: the storage tag this release's files are kept under (`a12-r345`), which the stage-2 workflow
  # needs to upload to. It comes from the GitHub adapter's own key mapping, not a second copy of it, and builds
  # no adapter (`ReleaseStorage.new(release, adapter: nil).tag`), so it answers even where storage is unset.
  #
  # @return [String]
  def tag
    ReleaseStorage::GithubAdapter.location_for(binary_key('app')).first
  end

  # Task 40i-c: the keys stage 2 (CI) must have uploaded a staged upload's files under, derived here from the
  # release and never taken from CI's word. The callback compares CI's reported keys with these and records
  # these, so a mismatch between CI's asset naming and the adapter's mapping fails loudly instead of leaving a
  # key that points at nothing. `universal` and `compressed` exist only for a bundle (an APK is served as is).
  #
  # Task 41b: with a `base` (`ReleaseArtifactName.for(release)`) every file is named after the app and release
  # (`binary/<base>.aab`, `pipeline/<base>.apk`, `pipeline/<base>.apks.br`, `icons/<base>.png`); without one the
  # old names are returned (`binary/<uploaded name>`, `pipeline/universal.apk`, `pipeline/release.apks.br`,
  # `icons/icon.png`), which is what a workflow older than 41b still uploads.
  #
  # @param filename [String] the uploaded file's (sanitised) name, e.g. `app.aab`; only its extension is used
  #   when a `base` is given
  # @param icon_extension [String, nil] `.png` or `.webp` when stage 1 found an icon
  # @param base [String, nil] the release's artifact base name
  # @return [Hash{Symbol=>String}]
  def staged_keys(filename:, icon_extension: nil, base: nil)
    keys = if base.present?
             { file: binary_key("#{base}#{File.extname(filename)}"), universal: artifact_key("#{base}.apk"),
               compressed: artifact_key("#{base}.apks.br") }
           else
             { file: binary_key(filename), universal: artifact_key('universal.apk'),
               compressed: artifact_key('release.apks.br') }
           end
    keys[:icon] = icon_key("#{base.presence || 'icon'}#{icon_extension}") if icon_extension.present?
    keys
  end

  # Task 19d: yields a local filesystem path to the release's primary file,
  # guaranteed to exist for the duration of the block, whether or not this
  # host still has the local copy CarrierWave originally wrote. Callers that
  # only need to *read* the file (parse metadata, sign it, hash it) should
  # use this instead of `release.file.path` directly, because that path can
  # point at a file a redeploy has already removed.
  #
  # Uses the local copy when present (no network call); otherwise downloads
  # the mirrored copy (see ReleaseFileMirrorJob) to a tempdir that is cleaned
  # up once the block returns, even if it raises.
  #
  # @raise [MissingFileError] neither a local file nor a storage key/object
  #   exists for this release
  # @return whatever the block returns
  def with_local_file
    local = release.file&.path
    return yield(local) if local.present? && File.file?(local)

    key = release.file_storage_key
    raise MissingFileError, "release #{release.id} has no local file and was never mirrored to storage" if key.blank?

    Dir.mktmpdir("release-#{release.id}-") do |dir|
      fetched = adapter.get(key, File.join(dir, File.basename(key)))
      raise MissingFileError, "release #{release.id}: storage has no object for #{key}" unless fetched

      yield(fetched)
    end
  end

  private


  def binary_key(filename)
    "uploads/apps/a#{release.app.id}/r#{release.id}/binary/#{filename}"
  end

  def icon_key(filename)
    "uploads/apps/a#{release.app.id}/r#{release.id}/icons/#{filename}"
  end

  # Mirrors the directory convention CarrierWave's AppFileUploader already
  # uses (apps/a<app_id>/r<release_id>/...) so artifacts sit predictably
  # alongside the primary release file regardless of adapter.
  def artifact_key(filename)
    "uploads/apps/a#{release.app.id}/r#{release.id}/pipeline/#{filename}"
  end
end
