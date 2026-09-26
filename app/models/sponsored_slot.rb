# frozen_string_literal: true

# Task 31a: a paid placement date-window for one App, mirroring the real
# Play Store's own mechanism (the app's existing listing is the creative --
# no separate ad copy is authored anywhere; see the "sponsored placement"
# decision recorded in D-store's HANDOVER.md). Published verbatim as one
# entry in the app's `sponsored_slots[]` array in the catalog index (see
# CatalogIndex::Serializer#sponsored_slots_for).
class SponsoredSlot < ApplicationRecord
  belongs_to :app

  validates :starts_at, presence: true
  validates :ends_at, presence: true
  validate :ends_after_starts

  # Only what's still worth publishing -- an expired window has nothing
  # left to tell a reader building today's storefront. Ordered so the
  # soonest-to-start window is first, matching how a reader would want to
  # reason about "what's live or coming up next".
  scope :current_or_upcoming, -> { where('ends_at >= ?', Time.current) }
  scope :chronological, -> { order(:starts_at) }

  private

  def ends_after_starts
    return if starts_at.blank? || ends_at.blank?

    errors.add(:ends_at, 'must be after the start time') if ends_at <= starts_at
  end
end
