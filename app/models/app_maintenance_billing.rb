# frozen_string_literal: true

# Task 42g/42h: one row per app tracking its maintenance fee ($2 per month). The charges themselves are `Payment`
# rows with purpose 'maintenance'; this row says where the app stands: `paid_through` is the end of the period
# already paid, `next_charge_at` is when the next charge is due. `status`: pending (no maintenance payment has
# succeeded yet), active (paid through a future date), past_due (a charge failed or is overdue), cancelled.
#
# Rules (Task 42h, operator may change them here in one place):
# - The listing fee covers the first month (INCLUDED_MONTHS); the first maintenance charge is one month later.
# - A failed charge is retried every RETRY_AFTER.
# - An app not paid up for GRACE_DAYS past `paid_through` is suspended (taken off the catalog); `lapsed_at`
#   records that Zealot did it. A later successful maintenance payment brings it back.
class AppMaintenanceBilling < ApplicationRecord
  MONTHLY_FEE_CENTS = 200
  INCLUDED_MONTHS = 1
  GRACE_DAYS = 7
  RETRY_AFTER = 1.day
  STATUSES = %w[pending active past_due cancelled].freeze

  belongs_to :app
  belongs_to :user

  validates :status, inclusion: { in: STATUSES }
  validates :billing_period, inclusion: { in: Payment::BILLING_PERIODS }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :currency, presence: true
  validates :app_id, uniqueness: true

  scope :active, -> { where(status: 'active') }
  scope :due, -> { where(status: %w[active past_due]).where('next_charge_at <= ?', Time.current) }
  scope :lapse_candidates, lambda {
    where(status: %w[active past_due], lapsed_at: nil).where('paid_through < ?', GRACE_DAYS.days.ago)
  }

  # Opens the app's billing record when its listing-fee payment succeeds. Idempotent (a duplicate webhook
  # delivery returns the existing record). The mandate is the one B-PAY created with the listing fee.
  def self.open_for_listing_payment!(payment)
    existing = find_by(app_id: payment.app_id)
    return existing if existing

    first_due = Time.current + INCLUDED_MONTHS.months
    create!(app_id: payment.app_id, user_id: payment.user_id, status: 'active',
            hyperswitch_mandate_id: payment.hyperswitch_mandate_id, paid_through: first_due,
            next_charge_at: first_due)
  rescue ActiveRecord::RecordNotUnique
    find_by!(app_id: payment.app_id)
  end

  # Called when a maintenance Payment succeeds: records it and moves the paid-through date forward by one month,
  # starting from the later of now and the date already paid through (an early payment does not lose days).
  # Idempotent per payment. If Zealot had suspended the app for this lapse, it goes live again.
  def record_payment!(payment)
    return self if last_payment_id == payment.id

    start = [paid_through, Time.current].compact.max
    was_lapsed = lapsed_at.present?
    update!(status: 'active', last_payment_id: payment.id,
            hyperswitch_mandate_id: payment.hyperswitch_mandate_id || hyperswitch_mandate_id,
            paid_through: start + 1.month, next_charge_at: start + 1.month, lapsed_at: nil)
    app.go_live! if was_lapsed
    self
  end

  # A failed or refused charge: past due, and try again after RETRY_AFTER. It does not suspend by itself;
  # suspension follows `paid_through`, so the app keeps what it already paid for.
  def mark_past_due!(retry_at: RETRY_AFTER.from_now)
    update!(status: 'past_due', next_charge_at: retry_at)
  end

  # Takes a lapsed app off the catalog. Only a currently-live app is suspended (App#suspend!), and the lapse is
  # recorded only when that worked.
  def suspend_for_lapse!
    return false unless app.suspend!

    update!(lapsed_at: Time.current)
  end
end
