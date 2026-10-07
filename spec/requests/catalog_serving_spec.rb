# frozen_string_literal: true

require 'rails_helper'

# Task 45g: GET /catalog/index.json and /catalog/index.json.sig serve the exact signed bytes from the database.
# Written, NOT run (no Ruby or database in the sandbox that wrote it).
RSpec.describe 'Catalog index served from this host', type: :request do
  let(:key) { CatalogIndexSigningKey.generate! }
  let(:client) { instance_double(CatalogIndex::GithubPagesCommit) }
  let(:landed) { CatalogIndex::GithubPagesCommit::Result.new(status: :published, commit_sha: 'abc') }

  before { Zealot::TenantRegistry.reset! }

  it 'answers 404 for both files before any publish' do
    get '/catalog/index.json'
    expect(response).to have_http_status(:not_found)

    get '/catalog/index.json.sig'
    expect(response).to have_http_status(:not_found)
  end

  it 'serves the bytes a publish signed, untouched, so the signature verifies' do
    allow(client).to receive(:publish).and_return(landed)
    CatalogIndex::Publish.call(apps: [], client: client, key: key, hook_url: '')

    get '/catalog/index.json'
    body = response.body
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/json')
    expect(response.headers['Cache-Control']).to include('public')

    get '/catalog/index.json.sig'
    expect(response).to have_http_status(:ok)
    expect(response.body).to end_with("\n")
    expect(CatalogIndex::Ed25519.verify(key.public_key, body, response.body.strip)).to be true
  end

  it 'replaces the stored copy at the next publish and keeps one row for the default tenant' do
    allow(client).to receive(:publish).and_return(landed)
    CatalogIndex::Publish.call(apps: [], client: client, key: key, hook_url: '', now: Time.utc(2026, 10, 7, 10))
    CatalogIndex::Publish.call(apps: [], client: client, key: key, hook_url: '', now: Time.utc(2026, 10, 7, 11))

    expect(CatalogIndexSnapshot.count).to eq(1)
    expect(CatalogIndexSnapshot.first.generated_at).to eq(Time.utc(2026, 10, 7, 11))
  end

  it 'does not fail a publish whose snapshot cannot be stored' do
    allow(client).to receive(:publish).and_return(landed)
    allow(CatalogIndexSnapshot).to receive(:store!).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect(CatalogIndex::Publish.call(apps: [], client: client, key: key, hook_url: '').status).to eq(:published)
  end
end
