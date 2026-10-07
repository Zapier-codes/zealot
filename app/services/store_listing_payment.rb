# frozen_string_literal: true

# Task 42f: the one place that starts the listing-fee payment on B-PAY (Hyperswitch). The console's
# `Apps::StoreListingsController#pay` (Task 32) and the API's `POST /api/apps/:id/store_listing/pay` both call
# it, so the amount, the mandate setup and the failure handling cannot differ between the two doors.
#
# It only STARTS a payment: it creates a `pending` Payment row and a B-PAY payment, and returns the client
# secret the checkout needs. It never confirms or charges a card. The app goes live only when B-PAY's signed
# webhook (`HyperswitchWebhooksController`) reports success; nothing here, and no redirect, flips it.
class StoreListingPayment
  LISTING_FEE_CENTS = 1499
  # The Play Store's one-off registration fee. Shown struck through next to LISTING_FEE_CENTS as the "was" price
  # (the operator's decision, 2026-10-07); it is never charged and never sent to B-PAY.
  LIST_PRICE_CENTS = 2500
  CURRENCY = 'usd'

  class StartFailed < StandardError; end

  Started = Struct.new(:payment, :client_secret, keyword_init: true)

  class << self
    # @raise [StartFailed] B-PAY refused or was unreachable; the Payment row is kept as `failed`
    def start(app:, user:, return_url:)
      payment = Payment.create!(app: app, user: user, purpose: 'listing_fee', amount_cents: LISTING_FEE_CENTS,
                                currency: CURRENCY, status: 'pending')

      begin
        result = HyperswitchClient.create_payment(
          amount_cents: payment.amount_cents, currency: payment.currency,
          customer_id: "app-#{app.id}", return_url: return_url,
          setup_future_usage: 'off_session', metadata: { app_id: app.id, payment_id: payment.id }
        )
      rescue HyperswitchClient::Error => e
        Rails.logger.error("[StoreListingPayment] #{e.class}: #{e.message}")
        payment.mark_failed!(raw: e.message)
        raise StartFailed, e.message
      end

      payment.update!(hyperswitch_payment_id: result.payment_id, client_secret: result.client_secret)
      Started.new(payment: payment, client_secret: result.client_secret)
    end

    # The price as the pages and the API show it: what is charged, and the crossed-out Play Store price.
    def price_json
      { amount_cents: LISTING_FEE_CENTS, list_price_cents: LIST_PRICE_CENTS, currency: CURRENCY }
    end

    # The two values the browser checkout needs besides the client secret (set by the operator).
    def publishable_key
      ENV['HYPERSWITCH_PUBLISHABLE_KEY'].to_s.strip
    end

    def sdk_url
      ENV['HYPERSWITCH_SDK_URL'].to_s.strip
    end
  end
end
