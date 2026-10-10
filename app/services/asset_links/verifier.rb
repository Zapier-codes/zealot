# frozen_string_literal: true

require 'json'

# Z-P22 (Play Console parity): the deep-link verification checker. Android proves a https App Link by
# serving `https://<host>/.well-known/assetlinks.json` naming the app's package and its signing
# certificate SHA-256; the OS fetches that file and auto-verifies the link when the target matches.
# Play lets a developer declare the site association in the Console; here Zealot checks it instead.
#
# This service answers one honest question per deep link: does the app's own well-known file currently
# associate this package with this signing certificate? It only reads (one GET, short timeouts, bounded
# body); it never writes to the site. A link with no certificate to check against is reported as
# `no_certificate`, never a guess, and any network/parse failure is reported as its own state so the
# operator sees "could not tell" rather than a false "verified".
#
#   result = AssetLinks::Verifier.call(host: 'example.com', package_name: 'com.x.app', sha256: 'AB:..')
#   result.state   # :verified, :not_associated, :unreachable, :invalid, :no_certificate
#   result.entries # the parsed statements the file carries (empty unless it parsed)
#
# Hosts are validated first: an App Link is only ever an https origin, so a blank/hostile host is
# refused before any request leaves the process.
module AssetLinks
  class Verifier
    # Standard Webhooks-style bounded read; an assetlinks file is small.
    MAX_BODY_BYTES = 262_144
    OPEN_TIMEOUT = 5
    TIMEOUT = 10
    RELATION = 'delegate_permission/common.handle_all_urls'

    STATE_VERIFIED = :verified
    STATE_NOT_ASSOCIATED = :not_associated
    STATE_UNREACHABLE = :unreachable
    STATE_INVALID = :invalid
    STATE_NO_CERTIFICATE = :no_certificate

    Result = Struct.new(:state, :entries, :http_status, keyword_init: true) do
      def verified?
        state == STATE_VERIFIED
      end
    end

    # `sha256` is the app's signing-certificate SHA-256 as Zealot stores it (uppercase, colon-separated).
    # `adapter` lets a spec pass a Faraday test adapter (no request leaves the process).
    def self.call(host:, package_name:, sha256:, adapter: nil)
      new(host: host, package_name: package_name, sha256: sha256, adapter: adapter).call
    end

    def initialize(host:, package_name:, sha256:, adapter: nil)
      @host = normalize_host(host)
      @package_name = package_name.to_s.strip
      @sha256 = sha256.to_s.strip
      @adapter = adapter
    end

    def call
      return Result.new(state: STATE_INVALID, entries: []) unless valid_host?
      return Result.new(state: STATE_NO_CERTIFICATE, entries: []) if @sha256.blank?
      return Result.new(state: STATE_INVALID, entries: []) if @package_name.blank?

      response = connection.get(well_known_path)
      status = response.status.to_i
      return Result.new(state: STATE_UNREACHABLE, entries: [], http_status: status) unless status == 200
      return Result.new(state: STATE_INVALID, entries: [], http_status: status) if response.body.to_s.bytesize > MAX_BODY_BYTES

      entries = parse(response.body.to_s)
      return Result.new(state: STATE_INVALID, entries: [], http_status: status) if entries.nil?

      state = associated?(entries) ? STATE_VERIFIED : STATE_NOT_ASSOCIATED
      Result.new(state: state, entries: entries, http_status: status)
    rescue Faraday::Error
      Result.new(state: STATE_UNREACHABLE, entries: [])
    end

    private

    # `www.` is not stripped: the well-known file is served on the exact App Link host, and a redirect to
    # a different host is not followed or trusted.
    def normalize_host(value)
      host = value.to_s.strip.downcase
      host = host.sub(%r{\Ahttps?://}, '').sub(%r{/.*\z}, '').split(':').first
      host
    end

    # One label to 253 chars, only hostname characters, at least one dot, no leading/trailing hyphen per
    # label. Refuses an IP literal or a bare word so a mistyped host fails here, not mid-request.
    def valid_host?
      return false if @host.blank? || @host.length > 253
      return false unless @host.include?('.') && @host.match?(/\A[a-z0-9.-]+\z/)
      return false if @host.include?('..')

      @host.split('.').all? { |label| label.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/) }
    end

    def well_known_path
      '/.well-known/assetlinks.json'
    end

    def connection
      @connection ||= Faraday.new(url: "https://#{@host}", request: { open_timeout: OPEN_TIMEOUT, timeout: TIMEOUT }) do |f|
        f.adapter(*Array(@adapter || Faraday.default_adapter))
      end
    end

    # Returns the list of statements, or nil when the body is not the expected JSON array shape.
    def parse(body)
      parsed = JSON.parse(body)
      return nil unless parsed.is_a?(Array)

      parsed.select { |entry| entry.is_a?(Hash) }
    rescue JSON::ParserError
      nil
    end

    def associated?(entries)
      entries.any? do |entry|
        # `target` is a single object in assetlinks, never an array — do not wrap it in Array (which
        # would turn a Hash into its [key, value] pairs).
        target = entry['target']
        Array(entry['relation']).include?(RELATION) && target_matches?(target)
      end
    end

    def target_matches?(target)
      return false unless target.is_a?(Hash)

      namespace = target['namespace'].to_s
      package = target['package_name'].to_s
      fingerprints = Array(target['sha256_cert_fingerprints']).map { |f| f.to_s.strip.upcase }

      namespace == 'android_app' && package == @package_name && fingerprints.include?(@sha256.upcase)
    end
  end
end
