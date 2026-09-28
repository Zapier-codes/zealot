# frozen_string_literal: true

# Task 27d-d1: one screenshot or feature graphic on an app's store listing. Owned by the App, not
# by a release (docs/store_listing_graphics.md, "Owner of the assets"). This slice is data only:
# no uploader, no route, no reader. `sha256` and `storage_key` are filled by 27d-d2's mirror job,
# the same two-step 27d-a used for the release icon -- both are nil on every row this slice creates.
class ListingGraphic < ApplicationRecord
  belongs_to :app

  enum :kind, { screenshot: 'screenshot', feature_graphic: 'feature_graphic' }, prefix: :kind
  enum :device, { phone: 'phone' }, prefix: :device

  scope :ordered, -> { order(:position) }

  validates :content_type, :byte_size, :width, :height, presence: true
  validates :alt_text, length: { maximum: ListingGraphicRules::ALT_TEXT_MAX_LENGTH }, allow_nil: true

  # Mirrors the database check constraints so a bad row is refused before it hits Postgres, the
  # same belt-and-braces pattern ReleasePolicy and the App validations already use elsewhere.
  validate :within_play_rules
  validate :screenshot_slot_available, on: :create, if: :kind_screenshot?

  private

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
