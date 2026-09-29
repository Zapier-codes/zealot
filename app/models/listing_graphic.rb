# frozen_string_literal: true

# Task 27d-d1: one screenshot or feature graphic on an app's store listing. Owned by the App, not
# by a release (docs/store_listing_graphics.md, "Owner of the assets"). Data plus (27d-d2-b) the
# cleanup of its stored bytes; no route and no reader yet. `sha256` and `storage_key` are filled by
# 27d-d2-c's ingest step (bytes go straight to ListingGraphicStorage, no CarrierWave copy first) --
# both are nil on every row created before that.
class ListingGraphic < ApplicationRecord
  include ListingGraphicUrl

  belongs_to :app

  enum :kind, { screenshot: 'screenshot', feature_graphic: 'feature_graphic' }, prefix: :kind
  enum :device, { phone: 'phone' }, prefix: :device

  scope :ordered, -> { order(:position) }

  # Task 27d-d2-b: destroying a graphic (or its app) removes the stored bytes. Nothing is enqueued for a
  # row that never got a key (an ingest that failed before storing, or a row from before 27d-d2).
  after_destroy_commit :enqueue_storage_cleanup

  # Task 27d-e1: a graphic is part of the app's listing in the signed index, so adding, changing,
  # reordering or removing one republishes the owning tenant's catalog (see #republish_catalog_index).
  after_commit :republish_catalog_index

  validates :content_type, :byte_size, :width, :height, presence: true
  validates :alt_text, length: { maximum: ListingGraphicRules::ALT_TEXT_MAX_LENGTH }, allow_nil: true

  # Mirrors the database check constraints so a bad row is refused before it hits Postgres, the
  # same belt-and-braces pattern ReleasePolicy and the App validations already use elsewhere.
  validate :within_play_rules
  validate :screenshot_slot_available, on: :create, if: :kind_screenshot?

  private

  # Nothing to publish for an app that is not in the index (a draft, a suspended app: the index only
  # lists `listing_live` apps, and going live republishes on its own), or for a row that is only going
  # because its app is being destroyed. The tenant is the app's owner and no other, as for every other
  # index trigger (Task 37b-iii-s5); the default tenant is `nil`.
  #
  # One job per committed row: reordering N screenshots enqueues N publishes. Each publish rebuilds the
  # index from current state under the tenant's advisory lock, so extra ones are redundant, not wrong;
  # 27d-e2's reorder should update its rows in one transaction so only one commit fires per request.
  def republish_catalog_index
    return if destroyed_by_association
    return unless app&.listing_live?

    CatalogIndexPublishJob.enqueue_for(app.tenant)
  end

  def enqueue_storage_cleanup
    return if storage_key.blank?

    ListingGraphicStorageCleanupJob.perform_later(id, [storage_key])
  end

  # Runs the same file-fact checks ListingGraphicRules.file_violations runs at upload time (27d-d2
  # calls the module directly, before a record exists, so it can refuse before ever writing a
  # file). Here it is enforced again on the model so nothing can create an out-of-policy row by
  # any other path (console, import, a future admin action). `alpha` is not a column, so a
  # previously-accepted row is not re-checked for it on every future save; only the columns this
  # model actually stores are re-validated.
  def within_play_rules
    return if kind.blank? # the kind enum's own inclusion check has already failed; do not double-report

    ListingGraphicRules.size_violations(kind, width, height).each do |violation|
      errors.add(violation.attribute, violation.message)
    end
  end

  def screenshot_slot_available
    return unless app_id

    existing = ListingGraphic.where(app_id: app_id, kind: 'screenshot', device: device).count
    return if ListingGraphicRules.screenshot_slot_free?(existing)

    errors.add(:base, "an app may have at most #{ListingGraphicRules::MAX_SCREENSHOTS} screenshots per device")
  end
end
