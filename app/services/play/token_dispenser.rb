# frozen_string_literal: true

require 'json'
require 'net/http'
require 'timeout'
require 'uri'

module Play
  # Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 4): the self-hosted token dispenser.
  #
  # The Play import bridge's login path needs an anonymous AAS token. Depending on a third party's host (the
  # one named in the `playstoreapi` PyPI page) is the failure mode rule 4 exists to avoid, so this class
  # reads from an operator-run dispenser. It is the ONLY thing in Zealot that talks to the dispenser, and it
  # is a *credential boundary*: it reads nothing but its own ENV, and it deliberately never touches
  # `PlayCredential` or `PlayUploadKey` (the publishing credentials) — a token leaked from the dispenser
  # therefore carries no publishing authority. That separation is the whole point of rule 4 and is what the
  # spec pins.
  #
  # The shape follows `marzzzello/playstoreapi`'s `TokenDispenser`: a GET to the dispenser URL returns JSON
  # with `authToken` (some forks spell it `token` or `aas_token`). Anything else — a non-2xx, a timeout, a
  # non-JSON body, a body without a token — is a miss, never a raise, exactly like `Play::BackendRunner`, so
  # the adapter can fall back to the other backend rather than turning a dispenser outage into an error page.
  #
  # Transport is injectable (anything answering `call(method, url, headers:, body:)` with `.status`/`.body`,
  # the same interface `ReleaseStorage::GithubAdapter::HttpTransport` has), so this is unit-testable off
  # Rails. `url` must be HTTPS unless the operator explicitly allows plaintext for a private host
  # (`PLAY_DISPENSER_ALLOW_HTTP=true`), so a token is never sent in the clear by accident.
  class TokenDispenser
    Result = Struct.new(:ok, :token, :expires_at, :error, keyword_init: true) do
      def ok? = !!ok
    end

    TOKEN_KEYS = %w[authToken auth_token token aas_token aasToken].freeze
    DEFAULT_TIMEOUT = (ENV['PLAY_DISPENSER_TIMEOUT_SECONDS'] || 20).to_i
    MAX_TOKEN_BYTES = 4096

    def self.call(**kwargs) = new(**kwargs).call

    # `env:` is injectable so a spec can drive every branch without mutating ENV.
    def initialize(env: ENV, transport: nil, timeout: nil)
      @env = env
      @transport = transport
      @timeout = timeout || (env['PLAY_DISPENSER_TIMEOUT_SECONDS'] || DEFAULT_TIMEOUT).to_i
    end

    def url = @env['PLAY_DISPENSER_URL'].to_s.strip

    def enabled?
      cast_bool(@env.fetch('PLAY_DISPENSER_ENABLED', 'false')) && !url.empty?
    end

    # @return [Result] ok=true with `token`, or ok=false with `error`
    def call
      return Result.new(ok: false, error: 'dispenser disabled') unless enabled?
      return Result.new(ok: false, error: 'dispenser URL is not https') unless https_ok?

      response = Timeout.timeout(@timeout) do
        transport.call(:get, url, headers: headers, body: nil)
      end
      unless response.status.between?(200, 299)
        return Result.new(ok: false, error: "dispenser answered HTTP #{response.status}")
      end

      body = response.body.to_s
      parsed = JSON.parse(body)
      return Result.new(ok: false, error: 'dispenser returned no JSON object') unless parsed.is_a?(Hash)

      token = extract_token(parsed)
      return Result.new(ok: false, error: 'dispenser returned no token') if token.nil?
      return Result.new(ok: false, error: 'dispenser token is too long') if token.bytesize > MAX_TOKEN_BYTES

      Result.new(ok: true, token: token, expires_at: extract_expiry(parsed))
    rescue JSON::ParserError
      Result.new(ok: false, error: 'dispenser output was not JSON')
    rescue Timeout::Error
      Result.new(ok: false, error: "dispenser timed out after #{@timeout}s")
    rescue StandardError => e
      Result.new(ok: false, error: "dispenser failed: #{e.class}")
    end

    private

    # Bearer wins when set; otherwise HTTP Basic. Never logged, and never read from the publishing models.
    def headers
      h = { 'Accept' => 'application/json', 'User-Agent' => 'zealot-play-dispenser' }
      token = @env['PLAY_DISPENSER_TOKEN'].to_s.strip
      user = @env['PLAY_DISPENSER_USER'].to_s
      password = @env['PLAY_DISPENSER_PASSWORD'].to_s
      if !token.empty?
        h['Authorization'] = "Bearer #{token}"
      elsif !user.empty?
        h['Authorization'] = basic_auth(user, password)
      end
      h
    end

    def basic_auth(user, password)
      "Basic #{["#{user}:#{password}"].pack('m0')}"
    end

    def extract_token(parsed)
      TOKEN_KEYS.each do |key|
        value = parsed[key]
        return value if value.is_a?(String) && !value.strip.empty?
      end
      nil
    end

    # The dispenser usually returns `expiry`/`expiresAt` in ms since epoch; when absent the caller simply
    # does not know the lifetime (nil), rather than assuming one.
    def extract_expiry(parsed)
      raw = parsed['expiry'] || parsed['expiresAt'] || parsed['expires_at']
      return nil if raw.nil?

      number = Integer(raw.to_s, 10, exception: false)
      return nil if number.nil?

      Time.at(number > 1_000_000_000_000 ? number / 1000 : number).utc
    end

    def https_ok?
      return true if @env['PLAY_DISPENSER_ALLOW_HTTP'].to_s.downcase == 'true'

      url.downcase.start_with?('https://')
    end

    def cast_bool(value)
      %w[true 1 yes on].include?(value.to_s.strip.downcase)
    end

    def transport
      @transport ||= ReleaseStorage::GithubAdapter::HttpTransport.new
    end
  end
end
