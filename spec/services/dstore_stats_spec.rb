# frozen_string_literal: true

require 'rails_helper'

# Task 31b-a. Written without being run (no Ruby in the authoring sandbox).
RSpec.describe DstoreStats do
  let(:url) { 'https://dstore.example/api/stats' }
  let(:document) do
    {
      'generated_at' => '2026-10-01T10:00:00Z',
      'traffic' => {
        'total_installs' => 12, 'total_views' => 90, 'apps_tracked' => 2,
        'per_app' => [{ 'slug' => 'whatsapp', 'install_count' => 10, 'view_count' => 80 },
                      { 'slug' => 'signal', 'install_count' => 2, 'view_count' => 10 }]
      },
      'searches' => { 'total' => 5, 'distinct_queries' => 2, 'top' => [{ 'query' => 'chat', 'count' => 4 }] },
      'reports' => { 'total' => 3, 'by_status' => { 'open' => 2, 'closed' => 1 }, 'by_reason' => { 'Other' => 3 } },
      'reviews' => { 'total' => 0, 'average_rating' => nil, 'per_app' => [] }
    }
  end
  let(:requests) { [] }

  def stub_dstore(status: 200, body: JSON.generate(document), raise_error: nil)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get('/api/stats') do |env|
        raise raise_error if raise_error

        requests << { method: env.method, headers: env.request_headers.dup }
        [status, { 'Content-Type' => 'application/json' }, body]
      end
    end
    allow(Faraday).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options) { |f| f.adapter :test, stubs }
    end
  end

  def with_env(env)
    stub_const('ENV', ENV.to_hash.merge(env))
  end

  describe '.configured? and .fetch without config' do
    it 'is not configured with nothing set, and makes no request' do
      with_env('DSTORE_STATS_URL' => '', 'DSTORE_STATS_TOKEN' => '')
      expect(Faraday).not_to receive(:new)
      expect(described_class.fetch.status).to eq(:not_configured)
    end

    it 'needs both values, and an https URL (http only for localhost)' do
      with_env('DSTORE_STATS_URL' => url, 'DSTORE_STATS_TOKEN' => '')
      expect(described_class.configured?).to be(false)
      with_env('DSTORE_STATS_URL' => 'http://dstore.example/x', 'DSTORE_STATS_TOKEN' => 't')
      expect(described_class.configured?).to be(false)
      with_env('DSTORE_STATS_URL' => 'http://localhost:3000/api/stats', 'DSTORE_STATS_TOKEN' => 't')
      expect(described_class.configured?).to be(true)
      with_env('DSTORE_STATS_URL' => 'not a url', 'DSTORE_STATS_TOKEN' => 't')
      expect(described_class.configured?).to be(false)
    end
  end

  describe '.fetch' do
    before { with_env('DSTORE_STATS_URL' => url, 'DSTORE_STATS_TOKEN' => 'secret-token') }

    it 'sends one GET with the bearer token and returns the validated document' do
      stub_dstore
      result = described_class.fetch

      expect(result).to be_ok
      expect(requests.size).to eq(1)
      expect(requests.first[:method]).to eq(:get)
      expect(requests.first[:headers]['Authorization']).to eq('Bearer secret-token')
      expect(result.stats[:traffic][:per_app].first).to eq(slug: 'whatsapp', install_count: 10, view_count: 80)
      expect(result.stats[:reviews][:average_rating]).to be_nil
      expect(result.stats[:reports][:by_status]).to eq('open' => 2, 'closed' => 1)
    end

    it 'maps 401 and 403 to unauthorized and other statuses to unavailable' do
      stub_dstore(status: 401, body: '')
      expect(described_class.fetch.status).to eq(:unauthorized)
      stub_dstore(status: 403, body: '')
      expect(described_class.fetch.status).to eq(:unauthorized)
      [404, 429, 500, 502, 503].each do |code|
        stub_dstore(status: code, body: '')
        expect(described_class.fetch.status).to eq(:unavailable), "status #{code}"
      end
    end

    it 'does not follow a redirect (a 3xx is unavailable)' do
      stub_dstore(status: 302, body: '')
      expect(described_class.fetch.status).to eq(:unavailable)
    end

    it 'treats a network failure as unavailable, without raising' do
      stub_dstore(raise_error: Faraday::ConnectionFailed.new('down'))
      expect(described_class.fetch.status).to eq(:unavailable)
    end

    it 'treats non-JSON, a wrong shape and an oversized body as invalid' do
      stub_dstore(body: 'not json')
      expect(described_class.fetch.status).to eq(:invalid)
      stub_dstore(body: '[]')
      expect(described_class.fetch.status).to eq(:invalid)
      stub_dstore(body: JSON.generate(document.merge('traffic' => 'x')))
      expect(described_class.fetch.status).to eq(:invalid)
      stub_dstore(body: JSON.generate(document.merge('padding' => 'a' * DstoreStats::MAX_BODY_BYTES)))
      expect(described_class.fetch.status).to eq(:invalid)
    end

    it 'never puts the token in the result' do
      stub_dstore
      expect(described_class.fetch.to_h.to_s).not_to include('secret-token')
      stub_dstore(status: 401, body: '')
      expect(described_class.fetch.to_h.to_s).not_to include('secret-token')
    end
  end

  describe DstoreStats::Document do
    it 'keeps only the contract keys, dropping anything extra such as free text or hashes' do
      noisy = document.deep_dup
      noisy['reviews']['comment'] = 'secret text'
      noisy['reports']['details'] = 'secret details'
      noisy['traffic']['per_app'].first['ip_hash'] = 'abc'
      parsed = described_class.parse(noisy)

      expect(parsed.to_s).not_to include('secret')
      expect(parsed.to_s).not_to include('ip_hash')
      expect(parsed.keys).to eq(%i[generated_at traffic searches reports reviews])
    end

    it 'rejects each wrong type' do
      bad = [
        ->(d) { d['generated_at'] = 5 },
        ->(d) { d['traffic']['total_views'] = -1 },
        ->(d) { d['traffic']['total_views'] = '90' },
        ->(d) { d['traffic']['total_views'] = 1.5 },
        ->(d) { d['traffic']['per_app'] = {} },
        ->(d) { d['traffic']['per_app'].first['slug'] = nil },
        ->(d) { d['searches']['top'] = [1] },
        ->(d) { d['reports']['by_status'] = { 'open' => 'x' } },
        ->(d) { d['reviews']['average_rating'] = 6 },
        ->(d) { d['reviews']['average_rating'] = 'high' },
        ->(d) { d.delete('reviews') }
      ]
      bad.each_with_index do |mutate, i|
        copy = document.deep_dup
        mutate.call(copy)
        expect(described_class.parse(copy)).to be_nil, "case #{i}"
      end
    end

    it 'accepts a null average with no reviews and a decimal average with some' do
      with = document.deep_dup
      with['reviews'] = { 'total' => 2, 'average_rating' => 4.5,
                          'per_app' => [{ 'slug' => 'whatsapp', 'count' => 2, 'average_rating' => 4.5 }] }
      expect(described_class.parse(with)[:reviews][:average_rating]).to eq(4.5)
      expect(described_class.parse(document)[:reviews][:average_rating]).to be_nil
    end
  end
end
