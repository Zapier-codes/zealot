# frozen_string_literal: true

# Task 42h: the recurring half of the $2/month per-app maintenance fee. Runs from cron (config/initializers/
# good_job.rb) and does two passes:
#   1. charge: every billing whose `next_charge_at` has passed gets one off-session charge on its stored B-PAY
#      mandate. It only STARTS the charge: a pending Payment row is created and B-PAY's signed webhook
#      (HyperswitchWebhooksController) is what marks it paid and extends `paid_through`.
#   2. lapse: every billing still unpaid GRACE_DAYS after `paid_through` has its app suspended.
# A charge that cannot be started (B-PAY unreachable or refusing) is recorded as a failed Payment and retried
# the next day. A billing with no stored mandate cannot be charged here; it is logged and left to lapse.
class AppMaintenanceBillingJob < ApplicationJob
  queue_as :schedule

  def perform
    charge_due
    suspend_lapsed
  end

  private

  def charge_due
    return logger.info('[AppMaintenanceBillingJob] B-PAY not configured; no charges started') unless HyperswitchClient.configured?

    AppMaintenanceBilling.due.find_each do |billing|
      charge(billing)
    rescue StandardError => e
      logger.error("[AppMaintenanceBillingJob] charge failed for billing #{billing.id}: #{e.class}: #{e.message}")
    end
  end

  def charge(billing)
    if billing.hyperswitch_mandate_id.blank?
      return logger.warn("[AppMaintenanceBillingJob] app #{billing.app_id} has no mandate; cannot charge")
    end
    return if pending_charge?(billing)

    payment = Payment.create!(app_id: billing.app_id, user_id: billing.user_id, purpose: 'maintenance',
                              billing_period: billing.billing_period, amount_cents: billing.amount_cents,
                              currency: billing.currency, status: 'pending')
    begin
      result = HyperswitchClient.charge_mandate(amount_cents: billing.amount_cents, currency: billing.currency,
                                                customer_id: "app-#{billing.app_id}",
                                                mandate_id: billing.hyperswitch_mandate_id)
      payment.update!(hyperswitch_payment_id: result.payment_id)
      # Not marked past due and not advanced: the webhook decides. If no webhook arrives, the pending row blocks
      # a second charge for a day, then the next run tries again.
    rescue HyperswitchClient::Error => e
      payment.mark_failed!(raw: e.message)
      billing.mark_past_due!
    end
  end

  # One charge in flight per app: a recent pending maintenance Payment means B-PAY has not answered yet.
  def pending_charge?(billing)
    Payment.pending.where(app_id: billing.app_id, purpose: 'maintenance')
           .exists?(['created_at > ?', AppMaintenanceBilling::RETRY_AFTER.ago])
  end

  def suspend_lapsed
    AppMaintenanceBilling.lapse_candidates.includes(:app).find_each do |billing|
      billing.suspend_for_lapse!
    rescue StandardError => e
      logger.error("[AppMaintenanceBillingJob] lapse failed for billing #{billing.id}: #{e.class}: #{e.message}")
    end
  end
end
