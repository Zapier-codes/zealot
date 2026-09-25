# frozen_string_literal: true

# Task 32. One row per charge attempt against B-PAY (self-hosted
# Hyperswitch) — the storefront's $14.99 one-time listing fee, or one cycle
# of the $2/mo (or $9.99/6mo, or custom-annual) maintenance fee. Recurring
# charges reuse `hyperswitch_mandate_id` from the listing-fee payment rather
# than re-collecting card details (see HyperswitchClient#charge_mandate).
#
# `purpose` (listing_fee/maintenance) is deliberately a different field
# from PublisherProfile#kind (individual/company) — do not conflate them,
# they answer different questions about different records.
#
# A succeeded listing_fee Payment is what calls App#go_live! (see
# HyperswitchWebhooksController) — this is the real integration point Task
# 25 left open ("the payment slice will call App#go_live! ... and this
# \[mark_paid\] action goes away").
class Payment < ApplicationRecord
  # Only the raw B-PAY response is encrypted (matches the `encrypts
  # :service_account_json` precedent on PlayCredential — this repo's
  # existing pattern for "not a secret we generated, but sensitive enough
  # not to sit in plaintext").
  encrypts :hyperswitch_raw_response

  belongs_to :app
  belongs_to :user

  PURPOSES = %w[listing_fee maintenance].freeze
  BILLING_PERIODS = %w[monthly semiannual annual].freeze
  STATUSES = %w[pending succeeded failed refunded].freeze

  validates :purpose, inclusion: { in: PURPOSES }
  validates :billing_period, inclusion: { in: BILLING_PERIODS }, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, presence: true
  validate :billing_period_only_on_maintenance

  scope :succeeded, -> { where(status: 'succeeded') }
  scope :pending, -> { where(status: 'pending') }
  scope :due_for_charge, -> { succeeded.where(purpose: 'maintenance').where('next_charge_at <= ?', Time.current) }

  def succeeded?
    status == 'succeeded'
  end

  def listing_fee?
    purpose == 'listing_fee'
  end

  def maintenance?
    purpose == 'maintenance'
  end

  # Called from HyperswitchWebhooksController once B-PAY confirms the charge
  # — the webhook, not the checkout redirect, is what's trusted.
  def mark_succeeded!(hyperswitch_payment_id:, mandate_id: nil, raw: nil)
    update!(
      status: 'succeeded',
      hyperswitch_payment_id: hyperswitch_payment_id,
      hyperswitch_mandate_id: mandate_id || hyperswitch_mandate_id,
      hyperswitch_raw_response: raw,
      paid_at: Time.current
    )
  end

  def mark_failed!(raw: nil)
    update!(status: 'failed', hyperswitch_raw_response: raw)
  end

  # No refund path is ever called automatically anywhere in this codebase —
  # Play's own registration fee is non-refundable regardless of outcome,
  # and Task 32 mirrors that for B-PAY (handover.md ❓1, resolved). This
  # method exists for a manual admin action, not an automatic one.
  def mark_refunded!(raw: nil)
    update!(status: 'refunded', hyperswitch_raw_response: raw)
  end

  private

  def billing_period_only_on_maintenance
    return if billing_period.blank? || purpose == 'maintenance'

    errors.add(:billing_period, 'can only be set when purpose is maintenance')
  end
end
