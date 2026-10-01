# frozen_string_literal: true

require 'rails_helper'

# Task 34a-3 (Storeapp leaf `f.xiv`): the listing text over the API (stage, publish, discard) with the
# user token or a per-app token (header only, own app only). Written by imitating
# api_app_token_upload_spec.rb; NOT run (the operator said no testing).
RSpec.describe 'API listing edit', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def call(verb, path, secret: nil, **params)
    public_send(verb, path, params: params, headers: secret ? bearer(secret) : {})
  end

  def path(target = app, suffix = '')
    "/api/apps/#{target.id}/listing_edit#{suffix}"
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  it 'refuses every action with no credential' do
    call(:get, path)
    expect(response).to have_http_status(:unauthorized)
    call(:patch, path, name: 'x')
    expect(response).to have_http_status(:unauthorized)
    call(:post, path(app, '/commit'))
    expect(response).to have_http_status(:unauthorized)
    call(:delete, path)
    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    call(:patch, path, secret: "#{AppApiToken::PREFIX}wrong", token: owner.token, name: 'New name')

    expect(response).to have_http_status(:unauthorized)
    expect(app.listing_edits.status_draft).to be_empty
  end

  it 'refuses a valid token for another app (403)' do
    call(:patch, path(other_app), secret: issued.secret, name: 'Hijacked')

    expect(response).to have_http_status(:forbidden)
    expect(other_app.reload.name).to eq('Other App')
  end

  it 'stages a change without touching the live listing' do
    call(:patch, path, secret: issued.secret, name: 'New name')

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body['draft']).to be(true)
    expect(body['staged']).to eq('name' => 'New name')
    expect(body['would_publish']['name']).to eq('New name')
    expect(app.reload.name).to eq('Token App')
  end

  it 'publishes the draft on commit and the live listing changes' do
    call(:patch, path, secret: issued.secret, name: 'New name')

    call(:post, path(app, '/commit'), secret: issued.secret)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['committed']).to be(true)
    expect(app.reload.name).to eq('New name')
    expect(app.listing_edits.status_draft).to be_empty
  end

  it 'discards the draft and leaves the live listing alone' do
    call(:patch, path, secret: issued.secret, name: 'New name')

    call(:delete, path, secret: issued.secret)

    expect(response).to have_http_status(:ok)
    expect(app.reload.name).to eq('Token App')
    expect(app.listing_edits.status_draft).to be_empty
  end

  it 'answers 404 for commit and discard when there is no draft' do
    call(:post, path(app, '/commit'), secret: issued.secret)
    expect(response).to have_http_status(:not_found)

    call(:delete, path, secret: issued.secret)
    expect(response).to have_http_status(:not_found)
  end

  it 'answers 422 and stages nothing for a blank name (the App validations)' do
    call(:patch, path, secret: issued.secret, name: '   ')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload.name).to eq('Token App')
  end

  it 'answers 422 when no listing field is sent, and ignores a field outside the text set' do
    call(:patch, path, secret: issued.secret, category: 'tools')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload.category).not_to eq('tools')
  end

  it 'works with the user token too' do
    call(:patch, path, token: owner.token, short_description: 'A short line')

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['staged']).to eq('short_description' => 'A short line')
  end

  it 'refuses a revoked token' do
    issued.token.revoke!

    call(:get, path, secret: issued.secret)

    expect(response).to have_http_status(:unauthorized)
  end
end
