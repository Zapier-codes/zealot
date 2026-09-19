# frozen_string_literal: true

# Minimal Novu REST client (Task 16). Only what Zealot needs: trigger one
# workflow for one subscriber. Plain Faraday on purpose — no new gem, so
# Gemfile.lock stays untouched and the Docker build can't drift.
#
#   NovuClient.trigger(
#     workflow_id: 'zealot-notice',
#     to: { subscriberId: 'zealot-1', email: 'a@b.c' },
#     payload: { subject: '…' },
#     transaction_id: 'abc'
#   )
#
# Config (ENV):
#   NOVU_API_KEY   the environment's Secret Key (Novu dashboard → API Keys)
#   NOVU_API_URL   default https://api.novu.co  (EU: https://eu.api.novu.co, or
#                  your self-hosted API URL)
class NovuClient
  DEFAULT_API_URL = 'https://api.novu.co'
  TRIGGER_PATH = '/v1/events/trigger'

  class Error < StandardError; end

  # Worth retrying: network trouble, 429, 5xx.
  class TemporaryError < Error; end

  # Retrying can't help: bad key, unknown workflow, payload rejected, or Novu
  # accepted the request but did not process the trigger.
  class PermanentError < Error; end

  Result = Struct.new(:transaction_id, :status, :activity_feed_link, keyword_init: true)

  class << self
    def configured?
      api_key.present?
    end

    def api_key
      ENV['NOVU_API_KEY'].to_s.strip.presence
    end

    def api_url
      ENV['NOVU_API_URL'].to_s.strip.presence&.chomp('/') || DEFAULT_API_URL
    end

    def trigger(workflow_id:, to:, payload: {}, transaction_id: nil, overrides: nil)
      raise PermanentError, 'NOVU_API_KEY is not set' unless configured?

      body = { name: workflow_id, to: to, payload: payload }
      body[:transactionId] = transaction_id if transaction_id.present?
      body[:overrides] = overrides if overrides.present?

      response = connection.post(TRIGGER_PATH) do |req|
        req.body = JSON.generate(body)
      end
      handle(response, workflow_id)
    rescue Faraday::Error => e
      raise TemporaryError, "Novu request failed: #{e.class}: #{e.message}"
    end

    private

    def connection
      Faraday.new(
        url: api_url,
        headers: {
          'Authorization' => "ApiKey #{api_key}",
          'Content-Type' => 'application/json',
          'Accept' => 'application/json',
          'User-Agent' => 'Zealot'
        },
        request: { open_timeout: 5, timeout: 15 }
      )
    end

    def handle(response, workflow_id)
      status = response.status.to_i
      return parse_success(response, workflow_id) if status.between?(200, 299)

      message = "Novu #{status} for #{workflow_id}: #{error_message(response)}"
      raise TemporaryError, message if status == 429 || status >= 500

      raise PermanentError, message
    end

    # Novu answers 201 with { data: { acknowledged, status, transactionId } }
    # (older API versions return the fields at the top level, so accept both).
    def parse_success(response, workflow_id)
      json = parse_json(response.body)
      data = json['data'].is_a?(Hash) ? json['data'] : json

      unless data['acknowledged'] == true && data['status'].to_s == 'processed'
        detail = Array(data['error']).join('; ').presence || data['status'].presence || 'not acknowledged'
        raise PermanentError, "Novu did not process #{workflow_id}: #{detail}"
      end

      Result.new(transaction_id: data['transactionId'], status: data['status'],
                 activity_feed_link: data['activityFeedLink'])
    end

    def error_message(response)
      json = parse_json(response.body)
      message = json['message']
      message = message.join('; ') if message.is_a?(Array)
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
