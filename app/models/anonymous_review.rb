# frozen_string_literal: true

# Z-P9 (principle 2): one anonymous review, keyed by the device-bound `ReviewerKey`. One row per
# (app, reviewer_key) -- so a person has exactly one editable review per app, and re-posting edits it rather
# than adding a second. The row is public once it passes moderation (`status: published`); a review the
# automated moderator flags is `pending` until an owner decides, and a rejected one never publishes.
#
# Nothing here identifies a person: no name, no email, no IP stored. "Anonymous" is the point.
class AnonymousReview < ApplicationRecord
  include TenantOwned

  belongs_to :app
  belongs_to :reviewer_key

  MAX_BODY_LENGTH = 2000

  STATUSES = %w[published pending rejected].freeze

  validates :rating, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 5 }
  validates :body, length: { maximum: MAX_BODY_LENGTH }
  validates :status, inclusion: { in: STATUSES }

  scope :published, -> { where(status: 'published') }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  # The "verified install" mark is earned, never assumed: it is true only when the reviewer key is
  # attestation-verified AND the review carried the proof that the reviewed version was installed
  # (`AnonymousReviewService` decides; this just keeps it consistent with the key's own state).
  def marked_verified?
    verified_install? && reviewer_key&.attestation_verified?
  end
end
