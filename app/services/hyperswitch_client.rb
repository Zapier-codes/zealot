# frozen_string_literal: true

# Minimal B-PAY (the operator's self-hosted Hyperswitch instance) REST
# client for Task 32 (the payment slice Task 25 left open) — the
# storefront's listing fee and recurring maintenance fee. Plain Faraday on
# purpose, mirroring NovuClient
# (app/services/novu_client.rb): no new gem, Gemfile.lock stays untouched.
#
#   # One-time listing fee, and set up a mandate in the same call so the
#   # recurring maintenance fee doesn't need the card again:
#   HyperswitchClient.create_payment(
#     amount_cents: 1499, currency: 'usd', customer_id: "app-#{app.id}",
#     return_url: app_publish_return_url(app), setup_future_usage: 'off_session',
#     metadata: { app_id: app.id, kind: 'listing_fee' }
#   )
#
#   # A later maintenance cycle, charged against the stored mandate —
#   # no customer interaction required (merchant-initiated transaction):
#   HyperswitchClient.charge_mandate(
#     amount_cents: 200, currency: 'usd', customer_id: "app-#{app.id}",
#     mandate_id: payment.hyperswitch_mandate_id
#   )
#
# Config (ENV):
#   HYPERSWITCH_API_KEY   B-PAY's secret key — Control Center → Developer →
#                         API Keys → KeyManagement.res generates/reveals it.
#                         NOT the publishable/hash key from
#                         PublishableAndHashKeySection.res — that's a
#                         client-side SDK concern, unused here.
#   HYPERSWITCH_API_URL   default https://b-pay-backend-new.onrender.com
#
# Webhook signature verification (HyperswitchWebhooksController) is
# deliberately NOT implemented against a specific header/algorithm here —
# see that controller's comment for why; this client only covers the
# outbound API calls.
class HyperswitchClient
  DEFAULT_API_URL = 'https://b-pay-backend-new.onrender.com'
  PAYMENTS_PATH = '/payments'

  class Error < StandardError; end

  # Worth retrying: network trouble, 429, 5xx.
  class TemporaryError < Error; end

  # Retrying can't help: bad key, payload rejected, mandate not found, etc.
  class PermanentError < Error; end

  Result = Struct.new(:payment_id, :status, :mandate_id, :client_secret, :raw, keyword_init: true)

  class << self
    def configured?
      api_key.present?
    end

    def api_key
      ENV['HYPERSWITCH_API_KEY'].to_s.strip.presence
    end

    def api_url
      ENV['HYPERSWITCH_API_URL'].to_s.strip.presence&.chomp('/') || DEFAULT_API_URL
    end

    # Creates (and, with confirm: true, attempts to confirm) a payment.
    # `setup_future_usage: 'off_session'` is what makes B-PAY return a
    # mandate alongside the payment result, per Hyperswitch's
    # mandates-and-recurring-payments model — pass it for the listing fee so
    # one checkout covers both the one-time charge and future maintenance
    # billing.
    def create_payment(amount_cents:, currency:, customer_id:, return_url:, confirm: true,
                        setup_future_usage: nil, payment_method_data: nil, metadata: {})
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      body = {
        amount: amount_cents,
        currency: currency.to_s.upcase,
        customer_id: customer_id,
        confirm: confirm,
        return_url: return_url,
        metadata: metadata
      }
      body[:setup_future_usage] = setup_future_usage if setup_future_usage.present?
      body[:payment_method_data] = payment_method_data if payment_method_data.present?

      post(PAYMENTS_PATH, body)
    end

    # Charges an existing mandate for a recurring maintenance cycle — a
    # merchant-initiated transaction (off_session: true), no card re-entry,
    # no customer present. `mandate_id` comes from the Payment row created
    # by the original listing-fee charge (Payment#hyperswitch_mandate_id).
    def charge_mandate(amount_cents:, currency:, customer_id:, mandate_id:)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      body = {
        amount: amount_cents,
        currency: currency.to_s.upcase,
        customer_id: customer_id,
        confirm: true,
        off_session: true,
        recurring_details: { type: 'mandate_id', data: mandate_id }
      }

      post(PAYMENTS_PATH, body)
    end

    def retrieve_payment(payment_id)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      response = connection.get("#{PAYMENTS_PATH}/#{payment_id}")
      handle(response, "retrieve #{payment_id}")
    rescue Faraday::Error => e
      raise TemporaryError, "B-PAY request failed: #{e.class}: #{e.message}"
    end

    private

    def post(path, body)
      response = connection.post(path) { |req| req.body = JSON.generate(body) }
      handle(response, path)
    rescue Faraday::Error => e
      raise TemporaryError, "B-PAY request failed: #{e.class}: #{e.message}"
    end

    def connection
      Faraday.new(
        url: api_url,
        headers: {
          'api-key' => api_key,
          'Content-Type' => 'application/json',
          'Accept' => 'application/json',
          'User-Agent' => 'Zealot'
        },
        request: { open_timeout: 5, timeout: 15 }
      )
    end

    def handle(response, context)
      status = response.status.to_i
      return parse_success(response) if status.between?(200, 299)

      message = "B-PAY #{status} for #{context}: #{error_message(response)}"
      raise TemporaryError, message if status == 429 || status >= 500

      raise PermanentError, message
    end

    def parse_success(response)
      json = parse_json(response.body)
      Result.new(
        payment_id: json['payment_id'],
        status: json['status'],
        mandate_id: json['mandate_id'],
        client_secret: json['client_secret'],
        raw: json
      )
    end

    def error_message(response)
      json = parse_json(response.body)
      error = json['error']
      message = error.is_a?(Hash) ? error['message'] : error
      message.presence || response.body.to_s.truncate(200)
    end

    def parse_json(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end
end
