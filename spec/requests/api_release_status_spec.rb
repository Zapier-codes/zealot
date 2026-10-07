# frozen_string_literal: true

require 'rails_helper'

# Task 31 (D-Store leaf 7.a.vi.zo): GET /api/releases/:id -- the read a CI job polls to see whether the
# compile finished. Accepts the user token or a per-app token (header only, own app only). Written by
# imitating api_release_release_spec.rb; NOT run (the standing operator instruction is no testing). Releases
# are built with `save!(validate: false)` because the repo has no release factory and a real upload needs an
# APK fixture.
RSpec.describe 'API release status', type: :request do
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

  def make_release(target_channel, status: 'held', **attributes)
    release = target_channel.releases.build(release_version: '1.0.0', build_version: '1', status: status, **attributes)
    release.save!(validate: false)
    release
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def read_it(release, secret: nil, **params)
    get "/api/releases/#{release.id}", params: params, headers: secret ? bearer(secret) : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }
  let(:held) { make_release(channel, status: 'held') }

  it 'refuses a request with no credential' do
    read_it(held)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    read_it(held, secret: "#{AppApiToken::PREFIX}wrong", token: owner.token)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses another app\'s release with a valid token (403)' do
    other_held = make_release(other_channel, status: 'held')

    read_it(other_held, secret: issued.secret)

    expect(response).to have_http_status(:forbidden)
  end

  it 'reads the status with the per-app token' do
    read_it(held, secret: issued.secret)

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body['id']).to eq(held.id)
    expect(body['status']).to eq('held')
    expect(body['signed']).to be(false)
    expect(body['app_id']).to eq(app.id)
  end

  it 'reads the compile outcome, so a CI job can stop polling' do
    held.update_columns(asset_delivery_state: 'failed', asset_delivery_error: 'bundletool not found')

    read_it(held, secret: issued.secret)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['asset_delivery_state']).to eq('failed')
    expect(response.parsed_body['asset_delivery_error']).to eq('bundletool not found')
  end

  it 'reads the status with the user token' do
    read_it(held, token: owner.token)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['status']).to eq('held')
  end
end
