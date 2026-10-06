# frozen_string_literal: true

require 'rails_helper'

# Task 36b-1. Written, NOT run (no testing by instruction). Google is stubbed through Faraday's test
# adapter, so no request leaves the process.
RSpec.describe GoogleAdc::Client do
  let(:credentials) { { client_id: 'cid', client_secret: 'csecret', refresh_token: 'rtoken' } }
  let(:now) { Time.utc(2026, 10, 3, 12, 0, 0) }
  let(:clock) { -> { now } }
  let(:token_calls) { [] }
  let(:api_calls) { [] }
  let(:account) { 'developerAccounts/123' }

  def build_client(&block)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/token') do |env|
        token_calls << env.body
        [200, { 'Content-Type' => 'application/json' }, JSON.generate(access_token: 'at-1', expires_in: 3600)]
      end
      block&.call(stub)
    end
    # The token endpoint is oauth2.googleapis.com/token; the test adapter matches on the path only.
    described_class.new(credentials: credentials, adapter: [:test, stubs], clock: clock)
  end

  # Accepts a hash or bare keywords (`json(developerAccounts: [])`), which Ruby 3 no longer turns into a positional hash.
  def json(body = nil, status: 200, **fields)
    body = fields if body.nil?
    [status, { 'Content-Type' => 'application/json' }, body.is_a?(String) ? body : JSON.generate(body)]
  end

  describe '.configured?' do
    it 'is false unless all three credentials are present' do
      stub_const('ENV', ENV.to_hash.merge('CLIENT_ID' => 'a', 'CLIENT_SECRET' => 'b', 'ADC_REFRESH_TOKEN' => ''))
      expect(described_class.configured?).to be(false)
    end

    it 'is true when all three are present' do
      stub_const('ENV', ENV.to_hash.merge('CLIENT_ID' => 'a', 'CLIENT_SECRET' => 'b', 'ADC_REFRESH_TOKEN' => 'c'))
      expect(described_class.configured?).to be(true)
    end
  end

  describe 'access token' do
    it 'is exchanged once and sent as a bearer token on later calls' do
      client = build_client do |stub|
        stub.get('/v1/developerAccounts') do |env|
          api_calls << env.request_headers['Authorization']
          json(developerAccounts: [])
        end
      end

      2.times { client.list_accounts }

      expect(token_calls.size).to eq(1)
      expect(token_calls.first).to include('grant_type=refresh_token', 'refresh_token=rtoken')
      expect(api_calls).to eq(['Bearer at-1', 'Bearer at-1'])
    end

    it 'is refreshed once it is within a minute of expiry' do
      # Clock reads, in order: set the first expiry; check on the second call (now inside the
      # one-minute margin); set the second expiry.
      times = [now, now + 3560, now + 3560]
      client = described_class.new(credentials: credentials, clock: -> { times.shift || (now + 3560) }, adapter: [:test, Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post('/token') do |env|
          token_calls << env.body
          json(access_token: "at-#{token_calls.size}", expires_in: 3600)
        end
        stub.get('/v1/developerAccounts') { json(developerAccounts: []) }
      end])

      client.list_accounts
      client.list_accounts

      expect(token_calls.size).to eq(2)
    end

    it 'explains an invalid_grant without logging the response body' do
      stubs = Faraday::Adapter::Test::Stubs.new do |stub|
        stub.post('/token') { json({ error: 'invalid_grant', error_description: 'Token has been expired or revoked.' }, status: 400) }
      end
      client = described_class.new(credentials: credentials, adapter: [:test, stubs], clock: clock)

      expect { client.list_accounts }.to raise_error(GoogleAdc::PermanentError, /invalid_grant.*7 days/m)
    end

    it 'refuses to start without all three credentials' do
      client = described_class.new(credentials: credentials.merge(refresh_token: ''), adapter: [:test, Faraday::Adapter::Test::Stubs.new], clock: clock)

      expect { client.list_accounts }.to raise_error(GoogleAdc::PermanentError, /must all be set/)
    end
  end

  describe '#verified_account_name' do
    it 'returns the single verified account' do
      client = build_client { |s| s.get('/v1/developerAccounts') { json(developerAccounts: [{ name: account, verificationState: 'VERIFIED' }]) } }

      expect(client.verified_account_name).to eq(account)
    end

    it 'refuses zero accounts' do
      client = build_client { |s| s.get('/v1/developerAccounts') { json({}) } }

      expect { client.verified_account_name }.to raise_error(GoogleAdc::PermanentError, /exactly one/)
    end

    it 'refuses more than one account' do
      two = [{ name: account, verificationState: 'VERIFIED' }, { name: 'developerAccounts/456', verificationState: 'VERIFIED' }]
      client = build_client { |s| s.get('/v1/developerAccounts') { json(developerAccounts: two) } }

      expect { client.verified_account_name }.to raise_error(GoogleAdc::PermanentError, /exactly one/)
    end

    it 'refuses an account that is not verified' do
      client = build_client { |s| s.get('/v1/developerAccounts') { json(developerAccounts: [{ name: account, verificationState: 'NOT_VERIFIED' }]) } }

      expect { client.verified_account_name }.to raise_error(GoogleAdc::PermanentError, /not VERIFIED/)
    end
  end

  describe 'error mapping' do
    it 'raises a PermanentError carrying Google\'s message on a 400, and logs the body' do
      client = build_client do |s|
        s.post("/v1/#{account}/androidPackages") { json({ error: { status: 'INVALID_ARGUMENT', message: 'Request contains an invalid argument.' } }, status: 400) }
      end
      allow(Rails.logger).to receive(:warn)

      expect { client.create_package(account, 'com.example.app') }
        .to raise_error(GoogleAdc::PermanentError, /INVALID_ARGUMENT: Request contains an invalid argument/)
      expect(Rails.logger).to have_received(:warn).with(/\[GoogleAdc\] 400/)
    end

    it 'treats 429 and 5xx as temporary' do
      client = build_client { |s| s.get('/v1/developerAccounts') { json({ error: { message: 'busy' } }, status: 503) } }

      expect { client.list_accounts }.to raise_error(GoogleAdc::TemporaryError)
    end

    it 'treats a 404 on get_package as "not there"' do
      client = build_client { |s| s.get("/v1/#{account}/androidPackages/com.example.app") { json({ error: { message: 'not found' } }, status: 404) } }

      expect(client.get_package("#{account}/androidPackages/com.example.app")).to be_nil
    end

    it 'never logs the access token' do
      client = build_client { |s| s.get('/v1/developerAccounts') { json({ error: { message: 'no' } }, status: 403) } }
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }

      expect { client.list_accounts }.to raise_error(GoogleAdc::PermanentError)
      expect(logged.join).not_to include('at-1')
    end
  end

  describe 'writes' do
    it 'sends the package name as the androidPackageId query' do
      seen = nil
      client = build_client do |s|
        s.post("/v1/#{account}/androidPackages") do |env|
          seen = URI.decode_www_form(env.url.query.to_s).to_h
          json(name: "#{account}/androidPackages/com.example.app", state: 'DRAFT')
        end
      end

      client.create_package(account, 'com.example.app')

      expect(seen).to include('androidPackageId' => 'com.example.app')
    end

    it 'refuses a package name that is not an Android application id' do
      client = build_client

      expect { client.create_package(account, '../evil') }.to raise_error(GoogleAdc::PermanentError, /not a valid package name/)
    end

    it 'sends the fingerprint as lower-case hex without colons' do
      sent = nil
      client = build_client do |s|
        s.post("/v1/#{account}/androidPackages/com.example.app/keys") do |env|
          sent = JSON.parse(env.body)
          json(name: "#{account}/androidPackages/com.example.app/keys/k1", state: 'REGISTERED')
        end
      end

      client.create_key("#{account}/androidPackages/com.example.app", ('AB:' * 31) + 'AB')

      expect(sent).to eq('certificateFingerprintSha256' => 'ab' * 32)
    end

    it 'refuses a malformed fingerprint' do
      client = build_client

      expect { client.create_key("#{account}/androidPackages/com.example.app", 'abc') }.to raise_error(GoogleAdc::PermanentError, /64 hex/)
    end
  end

  describe 'paging' do
    it 'follows nextPageToken until it is empty' do
      pages = []
      client = build_client do |s|
        s.get("/v1/#{account}/androidPackages") do |env|
          token = URI.decode_www_form(env.url.query.to_s).to_h['pageToken']
          pages << token
          token ? json(androidPackages: [{ packageName: 'b' }]) : json(androidPackages: [{ packageName: 'a' }], nextPageToken: 'p2')
        end
      end

      expect(client.list_packages(account).map { |p| p['packageName'] }).to eq(%w[a b])
      expect(pages).to eq([nil, 'p2'])
    end
  end
end
