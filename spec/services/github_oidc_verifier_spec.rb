# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a. Written by reading the code, NOT run (no Ruby in the sandbox that wrote it). Tokens are signed with
# a generated RSA key and served from a fake JWKS, so nothing here touches GitHub.
RSpec.describe GithubOidcVerifier do
  let(:key) { OpenSSL::PKey::RSA.generate(2048) }
  let(:kid) { 'test-key-1' }
  let(:now) { Time.zone.at(1_800_000_000) }
  let(:audience) { 'https://zealot.example' }
  let(:repository) { 'acme/storage' }
  let(:claims) do
    { 'iss' => described_class::ISSUER, 'aud' => audience, 'exp' => now.to_i + 300, 'nbf' => now.to_i - 5,
      'repository' => repository, 'event_name' => 'workflow_dispatch',
      'job_workflow_ref' => 'acme/storage/.github/workflows/read-upload.yml@refs/heads/main' }
  end

  def b64(data)
    Base64.urlsafe_encode64(data, padding: false)
  end

  def jwk_for(public_key, id)
    { 'kty' => 'RSA', 'use' => 'sig', 'kid' => id,
      'n' => b64(public_key.n.to_s(2)), 'e' => b64(public_key.e.to_s(2)) }
  end

  def token(payload: claims, header: { 'alg' => 'RS256', 'kid' => kid }, signer: key)
    input = "#{b64(JSON.generate(header))}.#{b64(JSON.generate(payload))}"
    signature = signer.sign(OpenSSL::Digest.new('SHA256'), input)
    "#{input}.#{b64(signature)}"
  end

  # A JWKS double that answers from `keys` and counts refetches.
  let(:keys) { [jwk_for(key.public_key, kid)] }
  let(:jwks) do
    Class.new do
      attr_reader :refreshes

      def initialize(keys)
        @keys = keys
        @refreshes = 0
      end

      def call(refresh: false)
        @refreshes += 1 if refresh
        @keys
      end
    end.new(keys)
  end

  def verifier(**overrides)
    described_class.new(**{ audience: audience, repository: repository, workflow: 'read-upload.yml', ref: 'main',
                            jwks: jwks, now: now }.merge(overrides))
  end

  it 'accepts a correctly signed token and returns its claims' do
    expect(verifier.call(token)['repository']).to eq(repository)
  end

  it 'accepts the audience with a trailing slash on either side' do
    expect(verifier(audience: "#{audience}/").call(token)).to be_a(Hash)
    expect(verifier.call(token(payload: claims.merge('aud' => "#{audience}/")))).to be_a(Hash)
  end

  it 'accepts a list of audiences that contains ours' do
    expect(verifier.call(token(payload: claims.merge('aud' => ['other', audience])))).to be_a(Hash)
  end

  it 'refuses a missing, oversized or malformed token' do
    expect { verifier.call(nil) }.to raise_error(described_class::Invalid)
    expect { verifier.call('a' * 9000) }.to raise_error(described_class::Invalid)
    expect { verifier.call('a.b') }.to raise_error(described_class::Invalid)
    expect { verifier.call('a.b.c') }.to raise_error(described_class::Invalid)
  end

  it 'refuses alg none and HS256, whatever the signature' do
    %w[none HS256].each do |alg|
      forged = token(header: { 'alg' => alg, 'kid' => kid })
      expect { verifier.call(forged) }.to raise_error(described_class::Invalid, /alg/)
    end
  end

  it 'refuses a token signed by a different key under a known kid' do
    expect { verifier.call(token(signer: OpenSSL::PKey::RSA.generate(2048))) }
      .to raise_error(described_class::Invalid, /signature/)
  end

  it 'refuses an unknown kid, after asking for fresh keys once' do
    expect { verifier.call(token(header: { 'alg' => 'RS256', 'kid' => 'nope' })) }
      .to raise_error(described_class::Invalid, /unknown signing key/)
    expect(jwks.refreshes).to eq(1)
  end

  it 'refuses each wrong claim' do
    {
      'iss' => 'https://evil.example', 'aud' => 'https://other.example', 'repository' => 'evil/storage',
      'event_name' => 'push',
      'job_workflow_ref' => 'acme/storage/.github/workflows/other.yml@refs/heads/main'
    }.each do |claim, value|
      expect { verifier.call(token(payload: claims.merge(claim => value))) }
        .to raise_error(described_class::Invalid), "accepted a wrong #{claim}"
    end
  end

  it 'refuses the right workflow on the wrong branch' do
    wrong = claims.merge('job_workflow_ref' => 'acme/storage/.github/workflows/read-upload.yml@refs/heads/evil')
    expect { verifier.call(token(payload: wrong)) }.to raise_error(described_class::Invalid, /workflow/)
  end

  it 'refuses an expired token and one that is not valid yet, allowing a minute of leeway' do
    expect { verifier.call(token(payload: claims.merge('exp' => now.to_i - 120))) }
      .to raise_error(described_class::Invalid, /expired/)
    expect(verifier.call(token(payload: claims.merge('exp' => now.to_i - 30)))).to be_a(Hash)
    expect { verifier.call(token(payload: claims.merge('nbf' => now.to_i + 120))) }
      .to raise_error(described_class::Invalid, /not yet/)
    expect { verifier.call(token(payload: claims.except('exp'))) }.to raise_error(described_class::Invalid)
  end

  describe GithubOidcVerifier::JwksFetcher do
    let(:cache) { ActiveSupport::Cache::MemoryStore.new }
    let(:response) { Struct.new(:status, :body) }
    let(:body) { JSON.generate('keys' => keys) }
    let(:transport) do
      calls = []
      fake = Object.new
      fake.define_singleton_method(:calls) { calls }
      fake.define_singleton_method(:call) do |*args, **kw|
        calls << [args, kw]
        Struct.new(:status, :body).new(200, body)
      end
      fake
    end

    it 'fetches once and then answers from the cache' do
      fetcher = described_class.new(transport: transport, cache: cache)
      2.times { fetcher.call }
      expect(transport.calls.length).to eq(1)
    end

    it 'refetches on request, but not more than once a minute' do
      fetcher = described_class.new(transport: transport, cache: cache)
      fetcher.call
      3.times { fetcher.call(refresh: true) }
      expect(transport.calls.length).to eq(2)
    end

    it 'turns an HTTP error into Invalid' do
      bad = Object.new
      bad.define_singleton_method(:call) { |*_a, **_k| Struct.new(:status, :body).new(503, '') }
      expect { described_class.new(transport: bad, cache: cache).call }
        .to raise_error(GithubOidcVerifier::Invalid, /503/)
    end
  end
end
