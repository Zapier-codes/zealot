# frozen_string_literal: true

require 'digest'

# Task 27d-d2-c: the one call that takes an image into an app's store listing. It is the first (and
# for now only) writer of `listing_graphics`:
#
#   result = ListingGraphicIngest.call(app: app, path: '/tmp/upload123', kind: 'screenshot', alt_text: 'Home screen')
#   result.ok?          # => true
#   result.graphic      # the saved ListingGraphic, with `sha256` and `storage_key` filled
#   result.violations   # => [] (or what Play would refuse, see ListingGraphicRules)
#
# In order: read the facts from the file's own bytes (ListingGraphicInspector, 27d-d2-a), judge them
# (ListingGraphicRules, 27d-d1) and check the device and the screenshot slot. Any refusal returns the
# violations and writes NOTHING: no row, no stored bytes. Otherwise, in one transaction under a lock on
# the app row (a savepoint if one is already open; so two uploads at once cannot take the same position or both overflow the cap):
#
#   - a screenshot takes the next free `position` (0, 1, 2 ...);
#   - a feature graphic takes position 0 and REPLACES the app's existing one (there is at most one per
#     device): the old row is destroyed first (the unique index would refuse two), and its stored bytes
#     are deleted only after the transaction commits, so a failed ingest leaves the old graphic intact;
#   - the row is created from the facts the BYTES gave (never from anything the caller says), with the
#     file's SHA-256;
#   - the bytes are stored (ListingGraphicStorage, 27d-d2-b) and `storage_key` is recorded.
#
# A storage failure rolls the row back and raises StorageFailed (an infrastructure problem, not
# something the uploader did wrong, so it is not a violation). If the bytes were already stored when a
# later step fails, they are deleted best-effort so nothing is orphaned.
#
# `path` must be a readable file the caller owns; it is only read, never moved or deleted, and its
# NAME is never used (the stored name comes from the detected content type).
class ListingGraphicIngest
  Result = Struct.new(:graphic, :violations, keyword_init: true) do
    def ok?
      violations.empty? && !graphic.nil?
    end
  end

  # The storage adapter failed or is not configured; nothing was kept.
  class StorageFailed < StandardError; end

  # @param adapter [#put, #delete] override the storage adapter (default: ReleaseStorage.build_adapter)
  # @return [Result]
  # @raise [StorageFailed]
  def self.call(app:, path:, kind:, alt_text: nil, device: 'phone', adapter: nil)
    new(app: app, path: path, kind: kind, alt_text: alt_text, device: device, adapter: adapter).call
  end

  def initialize(app:, path:, kind:, alt_text:, device:, adapter:)
    @app = app
    @path = path
    @kind = kind.to_s
    @alt_text = alt_text.presence
    @device = device.to_s
    @adapter = adapter
  end

  def call
    return refused([missing_file_violation]) unless @path && File.file?(@path)

    facts = ListingGraphicInspector.facts_from_file(@path)
    violations = check(facts)
    return refused(violations) unless violations.empty?

    ingest(facts)
  end

  private

  def check(facts)
    found = ListingGraphicRules.violations(kind: @kind, alt_text: @alt_text, **facts.to_h)
    unless ListingGraphicRules::DEVICES.include?(@device)
      found << ListingGraphicRules::Violation.new(:device, :device_unknown,
                                                  "device must be one of: #{ListingGraphicRules::DEVICES.join(', ')}")
    end
    found
  end

  def missing_file_violation
    ListingGraphicRules::Violation.new(:file, :file_missing, 'no file was provided')
  end

  def refused(violations)
    Result.new(graphic: nil, violations: violations)
  end

  # Returns a Result. The slot check runs inside the lock so it cannot be raced; a full slot is a
  # refusal, not an error, so it is reported the same way as any other violation.
  def ingest(facts)
    graphic = nil
    stored_key = nil
    replaced = nil
    violations = []

    ListingGraphic.transaction(requires_new: true) do
      @app.lock!
      scope = ListingGraphic.where(app_id: @app.id, kind: @kind, device: @device)

      if @kind == 'screenshot'
        unless ListingGraphicRules.screenshot_slot_free?(scope.count)
          violations << ListingGraphicRules::Violation.new(
            :base, :screenshot_slots_full,
            "an app may have at most #{ListingGraphicRules::MAX_SCREENSHOTS} screenshots per device"
          )
          raise ActiveRecord::Rollback
        end
        position = (scope.maximum(:position) || -1) + 1
      else
        replaced = scope.first
        replaced&.destroy!
        position = 0
      end

      graphic = create_row(facts, position)
      stored_key = store(graphic)
      graphic.update_columns(storage_key: stored_key)
    end

    return refused(violations) unless violations.empty?

    Result.new(graphic: graphic, violations: [])
  rescue StandardError
    discard_stored(graphic, stored_key)
    raise
  end

  def create_row(facts, position)
    ListingGraphic.create!(app: @app, kind: @kind, device: @device, position: position, alt_text: @alt_text,
                           content_type: facts.content_type, byte_size: facts.byte_size, width: facts.width,
                           height: facts.height, sha256: Digest::SHA256.file(@path).hexdigest)
  end

  def store(graphic)
    storage = ListingGraphicStorage.new(graphic, adapter: @adapter || ReleaseStorage.build_adapter)
    storage.store(@path)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    raise StorageFailed, "graphic could not be stored: #{e.message}"
  end

  # The transaction has rolled back, so the row is gone; take the bytes with it if they were written.
  def discard_stored(graphic, key)
    return if key.nil? || graphic.nil?

    (@adapter || ReleaseStorage.build_adapter).delete(key)
  rescue StandardError => e
    Rails.logger&.error("[ListingGraphicIngest] app #{@app.id}: could not remove orphaned #{key}: #{e.message}")
  end
end
