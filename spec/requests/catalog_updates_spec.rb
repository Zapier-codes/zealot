# frozen_string_literal: true

require 'rails_helper'

# Task 47d: GET /catalog/updates/:package_name, the check the injected updater makes. Written, NOT run (no
# Postgres or gems in the sandbox that wrote it).
RSpec.describe 'Catalog update check', type: :request do
  let(:answer) do
    { package_name: 'com.example.app', release_id: 7, version_code: '12', version_name: '1.2.0',
      download_url: 'https://zealot.test/download/releases/7', sha256: 'a' * 64, size_bytes: 1234,
      signing_fingerprint: 'AB:CD', min_sdk: '26', changelog: nil, released_at: '2026-10-09T01:00:00Z' }
  end

  it 'answers 200 JSON with public cache headers and no login' do
    allow(CatalogUpdateLookup).to receive(:call).with('com.example.app').and_return(answer)

    get '/catalog/updates/com.example.app'

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/json')
    expect(response.headers['Cache-Control']).to include('public')
    expect(response.headers['Access-Control-Allow-Origin']).to eq('*')
    expect(JSON.parse(response.body)).to include('version_code' => '12', 'sha256' => 'a' * 64, 'size_bytes' => 1234)
  end

  it 'answers 304 when the caller already has this answer' do
    allow(CatalogUpdateLookup).to receive(:call).and_return(answer)

    get '/catalog/updates/com.example.app'
    get '/catalog/updates/com.example.app', headers: { 'If-None-Match' => response.headers['ETag'] }

    expect(response).to have_http_status(:not_modified)
  end

  it 'answers 404 with an empty body when there is nothing to offer' do
    allow(CatalogUpdateLookup).to receive(:call).and_return(nil)

    get '/catalog/updates/com.example.unknown'

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_blank
  end

  it 'does not read the query string, so one cached answer serves every caller' do
    allow(CatalogUpdateLookup).to receive(:call).with('com.example.app').and_return(answer)

    get '/catalog/updates/com.example.app', params: { installed: '3', device: 'x' }

    expect(response).to have_http_status(:ok)
  end
end
