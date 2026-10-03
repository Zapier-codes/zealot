# frozen_string_literal: true

# Task 36b-2: Google's separate Android Developer ID Status API. It answers "is this package name
# registered?" for any caller with an API key; it needs no OAuth. Kept apart from `Client` because
# it is a different service, host and credential (ADC_API_KEY, optional).
#
# UNVERIFIED: the one attempt made while writing this (docs, section 6) used a damaged key and got
# `API_KEY_INVALID`, so the reply's shape has never been seen. This returns Google's parsed JSON
# untouched, for a person to read, and raises nothing the caller must interpret.
module GoogleAdc
  class StatusClient
    URL = 'https://androiddeveloperidstatus.googleapis.com'

    def self.configured?
      ENV['ADC_API_KEY'].to_s.strip.present?
    end

    def initialize(adapter: [Faraday.default_adapter])
      @adapter = adapter
    end

    # @return [Hash] Google's reply; or { 'error' => '...' } when the call failed (never raises)
    def check(package_name)
      return { 'error' => 'not a valid package name' } unless GoogleAdc.valid_package_name?(package_name)
      return { 'error' => 'ADC_API_KEY is not set' } unless self.class.configured?

      response = connection.get("/v1/packages/#{package_name}/packageRegistrationStatus:check")
      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed : { 'error' => "unexpected reply (HTTP #{response.status})" }
    rescue Faraday::Error, JSON::ParserError => e
      { 'error' => "#{e.class}: #{e.message}".truncate(200) }
    end

    private

    def connection
      Faraday.new(
        url: URL,
        headers: { 'X-Goog-Api-Key' => ENV['ADC_API_KEY'].to_s.strip, 'Accept' => 'application/json',
                   'User-Agent' => 'Zealot' },
        request: { open_timeout: 5, timeout: 15 }
      ) { |f| f.adapter(*@adapter) }
    end
  end
end
