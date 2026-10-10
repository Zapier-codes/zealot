# frozen_string_literal: true

# Z-P21 (Play Console parity): machine translation of a listing's free text. Plain Faraday, the same shape
# and reasons as NovuClient / BPayPayoutClient — no new gem, one place that knows the translation HTTP API.
#
# The API is the LibreTranslate / Argos-compatible shape (`POST {url}/translate`, JSON
# `{ q, source, target, format }` -> `{ translatedText }`), which both LibreTranslate and a self-hosted
# Argos Translate serve. Off by default: `configured?` is false until `ZEALOT_TRANSLATE_URL` is set, so
# nothing calls out unless the operator turns translation on, and a sandbox never does.
#
#   MachineTranslatorClient.translate('Hello', from: 'en', to: 'de') # => 'Hallo'
#
# Config (ENV):
#   ZEALOT_TRANSLATE_URL  e.g. https://libretranslate.internal  (blank = disabled)
#   ZEALOT_TRANSLATE_API_KEY  optional; sent as `api_key` when the server needs it
class MachineTranslatorClient
  class Error < StandardError; end

  # Network trouble, 429, 5xx — worth retrying.
  class TemporaryError < Error; end

  # Retrying can't help: a bad request, an unsupported pair, or translation is off.
  class PermanentError < Error; end

  class << self
    def configured?
      api_url.present?
    end

    def api_url
      ENV['ZEALOT_TRANSLATE_URL'].to_s.strip.presence&.chomp('/')
    end

    def api_key
      ENV['ZEALOT_TRANSLATE_API_KEY'].to_s.strip.presence
    end

    # Translate one string. `from` is 'en' (listings are authored in English); `to` is the target locale.
    # Returns the translated string, or raises. Never returns nil: an empty translation is an error, so a
    # caller can never store a blank over a real listing field.
    def translate(text, from:, to:)
      raise PermanentError, 'machine translation is not configured' unless configured?
      raise PermanentError, 'nothing to translate' if text.to_s.strip.empty?

      body = { q: text.to_s, source: from.to_s, target: to.to_s, format: 'text' }
      body[:api_key] = api_key if api_key.present?

      response = connection.post('/translate') do |req|
        req.body = JSON.generate(body)
      end
      parse(response, to)
    rescue Faraday::Error => e
      raise TemporaryError, "translation request failed: #{e.class}: #{e.message}"
    end

    # The source pairs this server offers, so the Console can only let an owner pick one it can serve.
    # Returns an array of [source, target] pairs, or [] when the server does not answer.
    def languages
      return [] unless configured?

      response = connection.get('/languages')
      json = parse_json(response.body)
      return [] unless json.is_a?(Array)

      json.flat_map do |entry|
        next [] unless entry.is_a?(Hash)

        targets = entry['targets']
        targets = [entry['code']] unless targets.is_a?(Array)
        targets.map { |target| [entry['code'].to_s, target.to_s] }
      end
    rescue Faraday::Error, Error
      []
    end

    private

    def connection
      Faraday.new(
        url: api_url,
        headers: { 'Content-Type' => 'application/json', 'Accept' => 'application/json',
                   'User-Agent' => 'Zealot' },
        request: { open_timeout: 5, timeout: 30 }
      )
    end

    def parse(response, target)
      status = response.status.to_i
      unless status.between?(200, 299)
        message = "translation #{status} for #{target}: #{error_message(response)}"
        raise TemporaryError, message if status == 429 || status >= 500

        raise PermanentError, message
      end

      translated = parse_json(response.body)['translatedText'].to_s
      raise PermanentError, "translation into #{target} was empty" if translated.strip.empty?

      translated
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      {}
    end

    def error_message(response)
      json = parse_json(response.body)
      json['error'].to_s.presence || response.body.to_s[0, 200]
    end
  end
end
