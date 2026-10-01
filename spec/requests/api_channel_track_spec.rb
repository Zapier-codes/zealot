# frozen_string_literal: true

require 'rails_helper'

# Task 34a-4 (Storeapp leaf `f.xiv`): PATCH /api/channels/:id can set `track`, with the user token or a
# per-app token (header only, own app only, and with a token ONLY `track` can change). Written by
# imitating api_app_token_upload_spec.rb; NOT run (the operator said no testing).
RSpec.describe 'API channel track', type: :request do
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

  def patch_channel(target, secret: nil, **params)
    patch "/api/channels/#{target.id}", params: params, headers: secret ? bearer(secret) : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  it 'refuses a request with no credential' do
    patch_channel(channel, track: 'internal')

    expect(response).to have_http_status(:unauthorized)
    expect(channel.reload.track).to eq('production')
  end

  it 'moves the channel with the user token' do
    patch_channel(channel, token: owner.token, track: 'internal')

    expect(response).to have_http_status(:ok)
    expect(channel.reload.track).to eq('internal')
  end

  it 'moves the channel with the app token' do
    patch_channel(channel, secret: issued.secret, track: 'closed')

    expect(response).to have_http_status(:ok)
    expect(channel.reload.track).to eq('closed')
  end

  it 'answers 422 for an unknown track and changes nothing' do
    patch_channel(channel, secret: issued.secret, track: 'nope')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(channel.reload.track).to eq('production')
  end

  it 'refuses a valid token on another app\'s channel (403)' do
    patch_channel(other_channel, secret: issued.secret, track: 'internal')

    expect(response).to have_http_status(:forbidden)
    expect(other_channel.reload.track).to eq('production')
  end

  it 'lets an app token change only the track, ignoring every other field' do
    patch_channel(channel, secret: issued.secret, track: 'open', name: 'Hijacked', password: 'x')

    expect(response).to have_http_status(:ok)
    expect(channel.reload.track).to eq('open')
    expect(channel.name).to eq("Channel #{app.name}")
    expect(channel.password).to be_blank
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    patch_channel(channel, secret: "#{AppApiToken::PREFIX}wrong", token: owner.token, track: 'internal')

    expect(response).to have_http_status(:unauthorized)
    expect(channel.reload.track).to eq('production')
  end

  it 'does not let an app token reach destroy (still user-token only)' do
    delete "/api/channels/#{channel.id}", headers: bearer(issued.secret)

    expect(response).to have_http_status(:unauthorized)
    expect(Channel.exists?(channel.id)).to be(true)
  end

  it 'refuses a revoked token' do
    issued.token.revoke!

    patch_channel(channel, secret: issued.secret, track: 'internal')

    expect(response).to have_http_status(:unauthorized)
  end
end
