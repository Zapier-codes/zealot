# frozen_string_literal: true

# Task 36b-1: a small client for Google's Android Developer Console API (version v1). Plain Faraday
# on purpose, mirroring HyperswitchClient: no new gem, Gemfile.lock untouched. See
# `docs/android_developer_console_api.md` for every path and field used here.
#
# Authentication is OAuth 2.0 only (Google refuses service accounts and API keys for this API). The
# client trades a stored refresh token for a short-lived access token and caches it until a minute
# before it expires:
#
#   client = GoogleAdc::Client.new
#   account = client.verified_account_name          # "developerAccounts/123..."
#   client.list_packages(account)                   # array of hashes, all pages
#
# Config (ENV): CLIENT_ID, CLIENT_SECRET, ADC_REFRESH_TOKEN. `configured?` is false unless all three
# are present.
#
# What this client never does: log an access token, a refresh token or a client secret. It does log
# Google's response body on every refusal (truncated), because Google's 400 answers for this API are
# terse and the body is the only clue (the doc records other developers hitting an unexplained 400).
#
# Written against Google's published definition, NOT run against the live service except for the two
# read calls recorded in the doc (account list, package list). Every other method is unexercised.
module GoogleAdc
  class Client
    API_URL = 'https://androiddeveloperconsole.googleapis.com'
    TOKEN_URL = 'https://oauth2.googleapis.com/token'
    REFRESH_MARGIN_SECONDS = 60
    PAGE_SIZE = 100
    MAX_PAGES = 50
    LOG_BODY_LIMIT = 2000
    INVALID_GRANT_HINT = ' (the refresh token was revoked or has lapsed; if the OAuth consent screen is in ' \
                         'Testing mode, tokens expire after 7 days)'

    def self.configured?
      credentials.values.all?(&:present?)
    end

    def self.credentials
      {
        client_id: ENV['CLIENT_ID'].to_s.strip,
        client_secret: ENV['CLIENT_SECRET'].to_s.strip,
        refresh_token: ENV['ADC_REFRESH_TOKEN'].to_s.strip
      }
    end

    # `adapter` is the Faraday adapter (and its arguments); specs pass `[:test, stubs]`.
    def initialize(credentials: self.class.credentials, adapter: [Faraday.default_adapter], clock: -> { Time.now })
      @credentials = credentials
      @adapter = adapter
      @clock = clock
      @access_token = nil
      @expires_at = nil
      @mutex = Mutex.new
    end

    def configured?
      @credentials.values.all?(&:present?)
    end

    # The one developer account this OAuth identity may act for (decision 36-6): exactly one account
    # must be returned and it must be VERIFIED. Anything else is a refusal, never a guess.
    def verified_account_name
      @verified_account_name ||= begin
        accounts = list_accounts
        unless accounts.size == 1
          raise PermanentError, "expected exactly one developer account, Google returned #{accounts.size}"
        end

        account = accounts.first
        unless account['verificationState'] == 'VERIFIED'
          raise PermanentError, "developer account is #{account['verificationState'].inspect}, not VERIFIED"
        end
        unless ACCOUNT_NAME_FORMAT.match?(account['name'].to_s)
          raise PermanentError, 'developer account name has an unexpected shape'
        end

        account['name']
      end
    end

    def list_accounts
      get_json('/v1/developerAccounts').fetch('developerAccounts', [])
    end

    def list_packages(account_name)
      paged("/v1/#{account_resource!(account_name)}/androidPackages", 'androidPackages')
    end

    # nil when the package does not exist under the account.
    def get_package(package_resource)
      get_json("/v1/#{package_resource!(package_resource)}")
    rescue NotFoundError
      nil
    end

    # Body is an empty AndroidPackage; the package name goes in the query (`androidPackageId`).
    # UNKNOWN until tried live: whether Google wants more in the body (doc, section 7).
    def create_package(account_name, package_name)
      unless GoogleAdc.valid_package_name?(package_name)
        raise PermanentError, "not a valid package name: #{package_name.inspect}"
      end

      post_json("/v1/#{account_resource!(account_name)}/androidPackages", {}, query: { androidPackageId: package_name })
    end

    def get_policy(package_resource)
      get_json("/v1/#{package_resource!(package_resource)}/registrationPolicy")
    end

    def list_keys(package_resource)
      paged("/v1/#{package_resource!(package_resource)}/keys", 'androidPackageKeys')
    end

    def create_key(package_resource, fingerprint_sha256)
      fingerprint = normalize_fingerprint(fingerprint_sha256)
      post_json("/v1/#{package_resource!(package_resource)}/keys", { certificateFingerprintSha256: fingerprint })
    end

    # Needed only when a known key's justificationRequirement is REQUIRED. Operator-triggered (36b-9).
    def justify_key(key_resource, justification)
      raise PermanentError, 'a justification is required' if justification.to_s.strip.empty?

      path = "/v1/#{key_resource!(key_resource)}:justifyAndroidPackageKeyRegistration"
      post_json(path, { justification: justification.to_s })
    end

    # Proves ownership of a key by uploading an APK signed with it that carries the verification token
    # (doc, section 5). Simple media upload to the path in Google's definition. Never called yet
    # (36b-8 is not built); kept so the client matches the definition.
    def verify_ownership(key_resource, apk_bytes)
      path = "/upload/v1/#{key_resource!(key_resource)}:verify"
      response = with_errors("verify #{key_resource}") do
        api_connection.post(path) do |req|
          req.params['uploadType'] = 'media'
          req.headers['Content-Type'] = 'application/octet-stream'
          req.body = apk_bytes
        end
      end
      handle(response, "verify #{key_resource}")
    end

    # A 404 from Google; a subclass so callers that only care about "it is not there" can rescue it.
    class NotFoundError < PermanentError; end

    private

    def get_json(path, query: {})
      response = with_errors("GET #{path}") { api_connection.get(path, query) }
      handle(response, "GET #{path}")
    end

    def post_json(path, body, query: {})
      response = with_errors("POST #{path}") do
        api_connection.post(path) do |req|
          req.params.update(query)
          req.body = JSON.generate(body)
        end
      end
      handle(response, "POST #{path}")
    end

    # Follows nextPageToken. MAX_PAGES guards against a token that never ends.
    def paged(path, list_key)
      items = []
      token = nil
      MAX_PAGES.times do
        query = { pageSize: PAGE_SIZE }
        query[:pageToken] = token if token.present?
        json = get_json(path, query: query)
        items.concat(json.fetch(list_key, []))
        token = json['nextPageToken'].to_s
        return items if token.empty?
      end
      raise PermanentError, "#{path} returned more than #{MAX_PAGES} pages"
    end

    def with_errors(context)
      yield
    rescue Faraday::Error => e
      raise TemporaryError, "Google request failed (#{context}): #{e.class}: #{e.message}"
    end

    def handle(response, context)
      status = response.status.to_i
      return parse_json(response.body) if status.between?(200, 299)

      log_refusal(status, context, response.body)
      message = "Google #{status} for #{context}: #{error_message(response.body)}"
      raise TemporaryError, message if status == 429 || status >= 500
      raise NotFoundError, message if status == 404

      raise PermanentError, message
    end

    def api_connection
      Faraday.new(
        url: API_URL,
        headers: {
          'Authorization' => "Bearer #{access_token}",
          'Content-Type' => 'application/json',
          'Accept' => 'application/json',
          'User-Agent' => 'Zealot'
        },
        request: { open_timeout: 5, timeout: 30 }
      ) { |f| f.adapter(*@adapter) }
    end

    def access_token
      @mutex.synchronize do
        return @access_token if @access_token && @expires_at && @clock.call < @expires_at - REFRESH_MARGIN_SECONDS

        refresh_access_token!
        @access_token
      end
    end

    def refresh_access_token!
      raise PermanentError, 'CLIENT_ID, CLIENT_SECRET and ADC_REFRESH_TOKEN must all be set' unless configured?

      connection = Faraday.new(url: TOKEN_URL, request: { open_timeout: 5, timeout: 15 }) { |f| f.adapter(*@adapter) }
      response = with_errors('token refresh') do
        connection.post do |req|
          req.headers['Content-Type'] = 'application/x-www-form-urlencoded'
          req.body = URI.encode_www_form(
            client_id: @credentials[:client_id],
            client_secret: @credentials[:client_secret],
            refresh_token: @credentials[:refresh_token],
            grant_type: 'refresh_token'
          )
        end
      end

      json = parse_json(response.body)
      status = response.status.to_i
      if status.between?(200, 299) && json['access_token'].present?
        @access_token = json['access_token']
        @expires_at = @clock.call + json['expires_in'].to_i
        return
      end

      # Never log the body of a token response beyond Google's own error code and description.
      detail = [json['error'], json['error_description']].compact.join(': ').presence || "HTTP #{status}"
      hint = json['error'] == 'invalid_grant' ? INVALID_GRANT_HINT : ''
      raise TemporaryError, "Google token refresh failed: #{detail}" if status == 429 || status >= 500

      raise PermanentError, "Google token refresh failed: #{detail}#{hint}"
    end

    def log_refusal(status, context, body)
      Rails.logger.warn("[GoogleAdc] #{status} for #{context}: #{body.to_s.truncate(LOG_BODY_LIMIT)}")
    end

    def error_message(body)
      error = parse_json(body)['error']
      message = error.is_a?(Hash) ? [error['status'], error['message']].compact.join(': ') : error
      message.presence || body.to_s.truncate(200)
    end

    def parse_json(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # Google wants the SHA-256 as a raw hex string. Accept "AA:BB:..." too and fold it to lower-case hex.
    def normalize_fingerprint(value)
      hex = value.to_s.delete(':').strip.downcase
      raise PermanentError, 'a SHA-256 fingerprint is 64 hex characters' unless hex.match?(/\A\h{64}\z/)

      hex
    end

    def account_resource!(name)
      raise PermanentError, "not a developer account name: #{name.inspect}" unless ACCOUNT_NAME_FORMAT.match?(name.to_s)

      name
    end

    def package_resource!(name)
      unless PACKAGE_RESOURCE_FORMAT.match?(name.to_s)
        raise PermanentError, "not an Android package resource name: #{name.inspect}"
      end

      name
    end

    def key_resource!(name)
      unless KEY_RESOURCE_FORMAT.match?(name.to_s)
        raise PermanentError, "not an Android package key resource name: #{name.inspect}"
      end

      name
    end
  end
end
