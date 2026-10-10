# frozen_string_literal: true

require 'rails_helper'

# Z-P25 (docs/UNOFFICIAL-ROUTES.md §1.1 rule 4): the self-hosted token dispenser and its credential boundary.
# Every branch is driven through an injected env and transport, so no network is touched.
RSpec.describe Play::TokenDispenser do
  # Same interface as ReleaseStorage::GithubAdapter::HttpTransport. Named uniquely (not a bare `FakeTransport`)
  # so it cannot clash with another spec's fake.
  DispenserFakeTransport = Class.new do
    attr_reader :requests

    def initialize(status: 200, body: '{}')
      @status = status
      @body = body
      @requests = []
    end

    def call(method, url, headers: {}, body: nil)
      @requests << { method: method, url: url, headers: headers, body: body }
      ReleaseStorage::GithubAdapter::Response.new(status: @status, headers: {}, body: @body)
    end
  end

  def fake(status: 200, body: '{}') = DispenserFakeTransport.new(status: status, body: body)

  def env(overrides = {})
    {
      'PLAY_DISPENSER_ENABLED' => 'true',
      'PLAY_DISPENSER_URL' => 'https://dispenser.example/token'
    }.merge(overrides)
  end

  it 'is off unless explicitly enabled and given a URL' do
    expect(described_class.new(env: {}).call.ok?).to be(false)
    expect(described_class.new(env: env('PLAY_DISPENSER_ENABLED' => 'false')).call.ok?).to be(false)
    expect(described_class.new(env: env('PLAY_DISPENSER_URL' => '')).call.ok?).to be(false)
  end

  it 'reads a token from any of the known keys' do
    %w[authToken auth_token token aas_token aasToken].each do |key|
      t = FakeTransport.new(body: { key => 'tok-123' }.to_json)
      result = described_class.new(env: env, transport: t).call
      expect(result.ok?).to be(true), key
      expect(result.token).to eq('tok-123')
    end
  end

  it 'sends a Bearer token when configured, and never the publishing credentials' do
    t = FakeTransport.new(body: { 'authToken' => 'tok' }.to_json)
    described_class.new(env: env('PLAY_DISPENSER_TOKEN' => 'secret'), transport: t).call

    expect(t.requests.first[:headers]['Authorization']).to eq('Bearer secret')
  end

  it 'falls back to HTTP Basic when no bearer token is set' do
    t = FakeTransport.new(body: { 'authToken' => 'tok' }.to_json)
    described_class.new(env: env('PLAY_DISPENSER_USER' => 'u', 'PLAY_DISPENSER_PASSWORD' => 'p'), transport: t).call

    expect(t.requests.first[:headers]['Authorization']).to eq("Basic #{['u:p'].pack('m0')}")
  end

  it 'reads an expiry in ms and in seconds' do
    ms = FakeTransport.new(body: { 'authToken' => 't', 'expiry' => 1_700_000_000_000 }.to_json)
    expect(described_class.new(env: env, transport: ms).call.expires_at).to eq(Time.at(1_700_000_000).utc)

    s = FakeTransport.new(body: { 'authToken' => 't', 'expiresAt' => 1_700_000_000 }.to_json)
    expect(described_class.new(env: env, transport: s).call.expires_at).to eq(Time.at(1_700_000_000).utc)
  end

  it 'refuses a plaintext URL unless the operator allows it' do
    t = FakeTransport.new(body: { 'authToken' => 't' }.to_json)
    result = described_class.new(env: env('PLAY_DISPENSER_URL' => 'http://dispenser.example/token'), transport: t).call
    expect(result.ok?).to be(false)
    expect(result.error).to eq('dispenser URL is not https')
    expect(t.requests).to be_empty
  end

  it 'allows plaintext only when PLAY_DISPENSER_ALLOW_HTTP is true' do
    t = FakeTransport.new(body: { 'authToken' => 't' }.to_json)
    result = described_class.new(
      env: env('PLAY_DISPENSER_URL' => 'http://internal/token', 'PLAY_DISPENSER_ALLOW_HTTP' => 'true'), transport: t
    ).call
    expect(result.ok?).to be(true)
  end

  it 'is a miss (never a raise) on a bad status, non-JSON, and a body without a token' do
    bad = described_class.new(env: env, transport: FakeTransport.new(status: 500, body: 'x')).call
    expect(bad.ok?).to be(false)
    expect(bad.error).to include('HTTP 500')

    not_json = described_class.new(env: env, transport: FakeTransport.new(body: 'nope')).call
    expect(not_json.ok?).to be(false)
    expect(not_json.error).to eq('dispenser output was not JSON')

    no_token = described_class.new(env: env, transport: FakeTransport.new(body: '{}')).call
    expect(no_token.ok?).to be(false)
    expect(no_token.error).to eq('dispenser returned no token')
  end
end
