# frozen_string_literal: true

# Task 27d-d2-b: where a store-listing graphic's bytes live. The graphic is owned by the App, not by a
# release (docs/store_listing_graphics.md), so ReleaseStorage (built around a release) does not fit;
# this class reuses its adapters instead, so the same RELEASE_STORAGE_ADAPTER setting (local, r2 or
# github) decides where graphics go and no new configuration exists.
#
#   storage = ListingGraphicStorage.new(graphic)   # the graphic must already be saved (it needs an id)
#   key = storage.store(local_path)                # => "uploads/apps/a12/graphics/g7/graphic.png"
#   storage.url_for(key)                           # signed URL, or nil on the local adapter
#   storage.fetch(key, to: path)                   # download to a local path, nil when the key is gone
#   storage.delete(key)
#
# The stored file name is fixed by the content type (`graphic.png` or `graphic.jpg`), never taken from
# the upload, so a hostile or odd file name can never reach a storage key. The key has no `r<id>`
# segment because a graphic belongs to no release; GithubAdapter maps the `graphics` segment to one
# GitHub release per app (tag `a<app>-graphics`).
#
# This class only moves bytes. It does not check them (ListingGraphicInspector and ListingGraphicRules
# do that before anything is stored) and it does not write `sha256` or `storage_key` on the row: that
# is the ingest step's job (27d-d2-c), so a failed store never leaves a row that points at nothing.
class ListingGraphicStorage
  EXTENSIONS = { 'image/png' => 'png', 'image/jpeg' => 'jpg' }.freeze

  attr_reader :graphic, :adapter

  # @param graphic [#id, #app_id, #content_type] a saved ListingGraphic
  # @raise [ArgumentError] the graphic has no id yet
  def initialize(graphic, adapter: ReleaseStorage.build_adapter)
    raise ArgumentError, 'the graphic must be saved before its bytes are stored' if graphic.id.blank?

    @graphic = graphic
    @adapter = adapter
  end

  # @return [String] the storage key the bytes were stored under
  # @raise [ArgumentError] the content type is not one Play accepts (a GIF never gets a key)
  # @raise [ReleaseStorage::StorageError] the adapter could not store the file
  def store(local_path)
    key = key_for(graphic.content_type)
    adapter.put(key, local_path, content_type: graphic.content_type)
    key
  end

  # @return [String, nil] `to`, or nil when the key does not exist in storage
  def fetch(key, to:)
    adapter.get(key, to)
  end

  # Best-effort URL for serving the graphic directly. nil on the local adapter, where the caller
  # falls back to `fetch` and `send_file`.
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

  def key_for(content_type)
    extension = EXTENSIONS[content_type]
    raise ArgumentError, "no storage extension for content type #{content_type.inspect}" unless extension

    "uploads/apps/a#{graphic.app_id}/graphics/g#{graphic.id}/graphic.#{extension}"
  end
end
