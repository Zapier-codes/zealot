# frozen_string_literal: true

# Z-P10 / Task 50: the payout half of the Console's revenue feature. Plain Faraday, same shape and same
# reasons as HyperswitchClient (app/services/hyperswitch_client.rb) — no new gem, Gemfile.lock untouched,
# one place that knows B-Pay's payout routes.
#
# B-Pay-backend (`Zapier-codes/B-Pay-backend`) carries the payouts feature in its default build; the routes
# below are read from its source (docs/UNOFFICIAL-ROUTES.md section 8):
#
#   POST /payouts/create
#   GET  /payouts/{id}                 PUT  /payouts/{id}
#   POST /payouts/{id}/confirm         /cancel         /fulfill
#   GET  /payouts/list                 /aggregate      /filter
#   PUT  /payouts/{id}/manual-update
#
# There is NO bulk-payout endpoint in the fork and no scheduler, so bulk and scheduled payouts are Zealot's
# own loop over `create` (+ `fulfill`) — see PayoutRunner.
#
# Config (ENV): HYPERSWITCH_API_KEY / HYPERSWITCH_API_URL, the same pair the payments client uses (B-Pay is
# one service; the payout and payment APIs share the merchant key).
class BPayPayoutClient
  DEFAULT_API_URL = 'https://b-pay-backend-new.onrender.com'
  PAYOUTS_PATH = '/payouts'

  class Error < StandardError; end

  # Network trouble, 429, 5xx — worth retrying.
  class TemporaryError < Error; end

  # Bad key, rejected payload, unknown payout — retrying cannot help.
  class PermanentError < Error; end

  Result = Struct.new(:payout_id, :status, :raw, keyword_init: true)

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

    # POST /payouts/create — ask B-Pay to create a payout. `connector` picks which payout connector handles
    # it (the fork ships code for 20-odd; see docs/UNOFFICIAL-ROUTES.md). `payout_method_id` is the stored
    # destination the publisher configured with B-Pay; we never carry raw bank details through Zealot.
    def create(amount_cents:, currency:, connector:, customer_id:, payout_method_id: nil,
               merchant_id: nil, metadata: {}, description: nil)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      body = {
        amount: amount_cents,
        currency: currency.to_s.upcase,
        connector: connector,
        customer_id: customer_id,
        metadata: metadata
      }
      body[:payout_method_id] = payout_method_id if payout_method_id.present?
      body[:merchant_id] = merchant_id if merchant_id.present?
      body[:description] = description if description.present?

      handle(post("#{PAYOUTS_PATH}/create", body), 'create')
    end

    # GET /payouts/{id}
    def retrieve(payout_id)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(get("#{PAYOUTS_PATH}/#{payout_id}"), "retrieve #{payout_id}")
    end

    # PUT /payouts/{id} — update a still-created payout before it is confirmed.
    def update(payout_id, attributes)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(put("#{PAYOUTS_PATH}/#{payout_id}", attributes), "update #{payout_id}")
    end

    # POST /payouts/{id}/confirm — move a requires_confirmation payout onward.
    def confirm(payout_id)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(post("#{PAYOUTS_PATH}/#{payout_id}/confirm", {}), "confirm #{payout_id}")
    end

    # POST /payouts/{id}/cancel
    def cancel(payout_id)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(post("#{PAYOUTS_PATH}/#{payout_id}/cancel", {}), "cancel #{payout_id}")
    end

    # POST /payouts/{id}/fulfill — the merchant marks an initiated payout fulfilled once the money is out.
    def fulfill(payout_id)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(post("#{PAYOUTS_PATH}/#{payout_id}/fulfill", {}), "fulfill #{payout_id}")
    end

    # GET /payouts/list — the merchant's payouts across every publisher (B-Pay is merchant-scoped, not
    # per-publisher). The Console's own per-publisher report reads the `payouts` table instead; this is for
    # an operator-wide view.
    def list(params = {})
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(get("#{PAYOUTS_PATH}/list", params), 'list')
    end

    # GET /payouts/aggregate — B-Pay's own totals (merchant-scoped).
    def aggregate(params = {})
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(get("#{PAYOUTS_PATH}/aggregate", params), 'aggregate')
    end

    # GET /payouts/filter — B-Pay's filtered list (merchant-scoped).
    def filter(params = {})
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(get("#{PAYOUTS_PATH}/filter", params), 'filter')
    end

    # PUT /payouts/{id}/manual-update — correct B-Pay's record of a payout (e.g. a status it got wrong).
    def manual_update(payout_id, attributes)
      raise PermanentError, 'HYPERSWITCH_API_KEY is not set' unless configured?

      handle(put("#{PAYOUTS_PATH}/#{payout_id}/manual-update", attributes), "manual-update #{payout_id}")
    end

    private

    def post(path, body)
      connection.post(path) { |req| req.body = JSON.generate(body) }
    rescue Faraday::Error => e
      raise TemporaryError, "B-Pay payout request failed: #{e.class}: #{e.message}"
    end

    def put(path, body)
      connection.put(path) { |req| req.body = JSON.generate(body) }
    rescue Faraday::Error => e
      raise TemporaryError, "B-Pay payout request failed: #{e.class}: #{e.message}"
    end

    def get(path, params = {})
      connection.get(path, params)
    rescue Faraday::Error => e
      raise TemporaryError, "B-Pay payout request failed: #{e.class}: #{e.message}"
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

      message = "B-Pay payout #{status} for #{context}: #{error_message(response)}"
      raise TemporaryError, message if status == 429 || status >= 500

      raise PermanentError, message
    end

    def parse_success(response)
      json = parse_json(response.body)
      Result.new(payout_id: json['payout_id'], status: json['status'], raw: json)
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
