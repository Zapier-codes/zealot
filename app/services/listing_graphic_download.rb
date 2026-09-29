# frozen_string_literal: true

require 'tmpdir'

# Task 27d-d2-d: decides where a store-listing graphic's bytes come from, in the 27d-b pattern
# (ReleaseIconDownload) but over ListingGraphicStorage, because a graphic has no CarrierWave copy:
#
#   1. a signed, short-lived URL from the storage adapter (R2, GitHub Releases) the caller redirects to; else
#   2. the bytes themselves, read back through the adapter (this is the local adapter's case, whose
#      files live under this host's disk and have no URL); else
#   3. nothing.
#
# `resolve` returns a Source: kind :redirect (url), :data (the bytes and the content type) or :missing.
# A graphic with no `storage_key` (never ingested), a content type Play does not accept, a key storage no
# longer has, and a misconfigured or unreachable storage all end as :missing, never as an error, so the
# public URL answers a plain 404 instead of a 500. The cap on a graphic (ListingGraphicRules::MAX_BYTES,
# 8 MB) is what makes reading the bytes into memory acceptable here.
class ListingGraphicDownload
  Source = Struct.new(:kind, :url, :data, :content_type, keyword_init: true)
  MISSING = Source.new(kind: :missing).freeze

  def initialize(graphic, storage: nil)
    @graphic = graphic
    @storage = storage
  end

  # Cheap and offline: is there anything to look for at all?
  def available?
    @graphic.storage_key.present? && ListingGraphicRules::ALLOWED_CONTENT_TYPES.include?(@graphic.content_type)
  end

  # @return [Source]
  def resolve
    return MISSING unless available?

    key = @graphic.storage_key
    url = storage.url_for(key)
    return Source.new(kind: :redirect, url: url) if url

    data = read(key)
    data ? Source.new(kind: :data, data: data, content_type: @graphic.content_type) : MISSING
  rescue ReleaseStorage::ConfigurationError, ReleaseStorage::StorageError => e
    Rails.logger&.error("[ListingGraphicDownload] graphic #{@graphic.id}: #{e.message}")
    MISSING
  end

  private

  def storage
    @storage ||= ListingGraphicStorage.new(@graphic)
  end

  # Reads through a tempdir that is always cleaned up, so nothing is left behind whatever the adapter is.
  def read(key)
    Dir.mktmpdir("graphic-#{@graphic.id}-") do |dir|
      fetched = storage.fetch(key, to: File.join(dir, 'graphic'))
      fetched && File.binread(fetched)
    end
  end
end
