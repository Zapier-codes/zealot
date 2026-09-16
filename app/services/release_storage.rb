# frozen_string_literal: true

# Storage abstraction for release-pipeline artifacts (Brotli-compressed APK
# sets, delta patches, asset pack splits) that sit alongside the primary
# CarrierWave-managed release file.
#
# This does NOT replace CarrierWave's handling of the original uploaded
# AAB/APK/IPA — that keeps working exactly as before. This is specifically
# for the artifacts the Play Asset Delivery / Brotli / delta pipeline
# produces, which need a storage target that can be local disk in
# development and Cloudflare R2 (S3-compatible) in production, without the
# calling code caring which.
#
# Usage:
#   storage = ReleaseStorage.new(release)
#   storage.store_compressed_apks(local_path)   # => storage key
#   storage.store_delta_patch(local_path, key: "12-34.bspatch")
#   storage.fetch(key, to: local_path)           # download to a local path
#   storage.url_for(key)                         # public/presigned URL, or nil
#   storage.delete(key)
#
# The adapter is chosen by RELEASE_STORAGE_ADAPTER ("local" or "r2"),
# defaulting to "local" so existing/dev setups keep working untouched.
class ReleaseStorage
  class ConfigurationError < StandardError; end
  class StorageError < StandardError; end

  def self.adapter_name
    ENV.fetch('RELEASE_STORAGE_ADAPTER', 'local').downcase
  end

  def self.build_adapter
    case adapter_name
    when 'local' then ReleaseStorage::LocalAdapter.new
    when 'r2' then ReleaseStorage::R2Adapter.new
    else
      raise ConfigurationError, "Unknown RELEASE_STORAGE_ADAPTER: #{adapter_name.inspect}. " \
                                 "Expected 'local' or 'r2'."
    end
  end

  attr_reader :release, :adapter

  def initialize(release, adapter: self.class.build_adapter)
    @release = release
    @adapter = adapter
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

  private

  # Mirrors the directory convention CarrierWave's AppFileUploader already
  # uses (apps/a<app_id>/r<release_id>/...) so artifacts sit predictably
  # alongside the primary release file regardless of adapter.
  def artifact_key(filename)
    "uploads/apps/a#{release.app.id}/r#{release.id}/pipeline/#{filename}"
  end
end
