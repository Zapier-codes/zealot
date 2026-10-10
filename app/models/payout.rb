# frozen_string_literal: true

# Z-P10 / Task 50. One payout attempt to a publisher, made through the program's payments service,
# B-Pay-backend (self-hosted Hyperswitch; see BPayPayoutClient). Play pays a developer what their apps
# earned; this is the record of one such transfer.
#
# `status` mirrors B-Pay's own payout lifecycle. It is written only from B-Pay's answer, never guessed:
#   created -> requires_confirmation (B-Pay produced a payout that needs confirming)
#           -> initiated (funds moving) -> succeeded / failed
#   cancelled is set when the publisher or an admin cancels before fulfilment.
#
# `raw_response` is the last full B-Pay body, kept the same sentinel way Payment keeps
# `hyperswitch_raw_response` — encrypted, because it is not a secret we generated but is sensitive enough not
# to sit in plaintext.
class Payout < ApplicationRecord
  encrypts :raw_response

  belongs_to :publisher_profile
  belongs_to :user

  STATUSES = %w[
    created requires_confirmation initiated pending succeeded failed cancelled
  ].freeze

  # The statuses that mean the money has not moved yet and the payout can still be cancelled.
  CANCELLABLE_STATUSES = %w[created requires_confirmation].freeze

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :succeeded, -> { where(status: 'succeeded') }
  scope :in_flight, -> { where(status: %w[created requires_confirmation initiated pending]) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def cancellable?
    CANCELLABLE_STATUSES.include?(status)
  end
end
