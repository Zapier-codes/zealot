# frozen_string_literal: true

require 'tmpdir'
require 'digest'
require 'fileutils'

# Task 43f-2 (operator-directed, 2026-10-07): puts a picture on the app's listing as its ICON, over the API.
# An app's icon is a column on a release (`Release#icon`), and the signed index reads it from the newest catalog
# release that has one (`CatalogIndex::Serializer#icon_for`). There is no console or API door to change it, so
# an app whose bundle carried no readable icon (Appstore, release 1.1.4) shows none. This is that door.
#
#   result = ListingIconIngest.call(app: app, path: '/tmp/icon.png')
#   result.ok?        # => true when the icon was put on the release
#   result.release    # => the release that now carries the icon
#   result.violations # => [Violation(code:, message:)] when refused (nothing was written)
#
# The picture is judged here from its own bytes (never its name): a PNG, exactly ICON_SIDE x ICON_SIDE, at most
# 1 MB (Play's icon rule, from memory, not re-read). `ListingGraphicFit` (kind: 'icon') makes any readable image
# meet it first; a caller that sends `fit=false` has to send it right.
#
# Which release: the newest of `app.catalog_releases` (production track, not held), the first place the index
# looks. No such release is a refusal (:no_release), not a guess.
#
# The two traps recorded in handover.md (Task 43, "Two traps found in the code, for 43f"):
#   1. `ReleaseFileMirrorJob#mirror` returns early when `icon_storage_key` is set, so the old key and hash are
#      cleared in the same save as the new file, or the old bytes keep being served from storage.
#   2. `Release::CATALOG_INDEX_RELEASE_FIELDS` has no icon column and the mirror job writes with
#      `update_columns`, so a changed icon republishes nothing by itself: the index is enqueued explicitly.
class ListingIconIngest
  ICON_SIDE = ListingGraphicFit::ICON_SIDE
  MAX_BYTES = 1024 * 1024

  Violation = Struct.new(:code, :message, keyword_init: true)

  Result = Struct.new(:release, :violations, keyword_init: true) do
    def ok?
      violations.empty?
    end
  end

  # @param publisher [#enqueue_for] republishes the catalog index (override in a spec)
  # @param mirror [#perform_later] copies the stored icon to ReleaseStorage (override in a spec)
  def self.call(app:, path:, publisher: CatalogIndexPublishJob, mirror: ReleaseFileMirrorJob)
    new(app: app, path: path, publisher: publisher, mirror: mirror).call
  end

  def initialize(app:, path:, publisher:, mirror:)
    @app = app
    @path = path
    @publisher = publisher
    @mirror = mirror
  end

  def call
    return refused(:no_file, 'no image file was received') unless @path && File.file?(@path)

    violations = check(ListingGraphicInspector.facts_from_file(@path))
    return Result.new(release: nil, violations: violations) unless violations.empty?

    release = @app.catalog_releases.first
    return refused(:no_release, 'the app has no published release to carry the icon yet; upload a release first') unless release

    attach(release)
    @mirror.perform_later(release.id)
    @publisher.enqueue_for(@app.tenant)
    Result.new(release: release, violations: [])
  rescue CarrierWave::IntegrityError, CarrierWave::ProcessingError, ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[ListingIconIngest] app #{@app.id}: #{e.class}: #{e.message}")
    refused(:not_stored, 'the icon could not be stored; nothing was changed')
  end

  private

  def check(facts)
    found = []
    unless facts.content_type == 'image/png'
      found << Violation.new(code: :not_png, message: 'must be a PNG (leave fitting on to convert a JPEG or WebP)')
    end
    if facts.width != ICON_SIDE || facts.height != ICON_SIDE
      found << Violation.new(code: :wrong_size, message: "must be exactly #{ICON_SIDE} x #{ICON_SIDE} px")
    end
    if facts.byte_size.to_i > MAX_BYTES
      found << Violation.new(code: :file_too_large, message: "must be #{MAX_BYTES / (1024 * 1024)} MB or smaller")
    end
    found
  end

  # The file is copied to a name ending .png first: the uploader judges the extension of what it is given and
  # a multipart temp file's name is not under our control.
  def attach(release)
    Dir.mktmpdir('zealot-icon') do |dir|
      copy = File.join(dir, 'icon.png')
      FileUtils.cp(@path, copy)
      File.open(copy, 'rb') do |io|
        release.icon = io
        release.icon_storage_key = nil
        release.icon_sha256 = nil
        release.save!(validate: false)
      end
    end
    record_sha256(release)
  end

  # Hash it now, while the stored copy is on local disk, so the index entry never goes out with a null hash
  # (the mirror job would record it later, but it republishes nothing).
  def record_sha256(release)
    stored = release.icon&.path
    return unless stored && File.file?(stored)

    release.update_columns(icon_sha256: Digest::SHA256.file(stored).hexdigest)
  end

  def refused(code, message)
    Result.new(release: nil, violations: [ Violation.new(code: code, message: message) ])
  end
end
