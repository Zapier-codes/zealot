# frozen_string_literal: true

require 'rails_helper'

# Task 34a-5 (Storeapp leaf `f.xiv`): POST /api/apps/upload accepts a per-app token (header only) and
# `hold=true`. Written by imitating api_app_token_spec.rb; NOT run (no Ruby, Rails or database in the
# sandbox that wrote it). Only the refusals are covered here: a successful upload needs a real APK
# fixture, which this repo does not carry, so the success path (token accepted, release created
# `held` with hold=true and `available` without) is NOT covered by any spec and stays "not verified".
RSpec.describe 'API upload with a per-app token', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }
  let!(:channel) { make_channel(app) }
  let!(:other_channel) { make_channel(other_app) }

  def make_channel(target)
    scheme = target.schemes.create!(name: "Scheme #{target.name}")
    scheme.channels.create!(name: "Channel #{target.name}", device_type: :android)
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def upload(secret: nil, **params)
    post '/api/apps/upload', params: params, headers: secret ? bearer(secret) : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  it 'refuses a request with no credential' do
    upload(channel_key: channel.key)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    upload(secret: "#{AppApiToken::PREFIX}wrong", token: owner.token, channel_key: channel.key)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'does not read the user token from a query param when a valid app token is sent for another app' do
    upload(secret: issued.secret, token: owner.token, channel_key: other_channel.key)

    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses an app token with no channel_key (a token never creates an app)' do
    upload(secret: issued.secret)

    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses a revoked token' do
    secret = issued.secret
    issued.token.revoke!
    upload(secret: secret, channel_key: channel.key)

    expect(response).to have_http_status(:unauthorized)
  end
end
