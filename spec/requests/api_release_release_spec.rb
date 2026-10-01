# frozen_string_literal: true

require 'rails_helper'

# Task 34a-6 (Storeapp leaf `f.xiv`): POST /api/releases/:id/release makes a HELD release available,
# with the user token or a per-app token (header only, own app only). Written by imitating
# api_app_token_upload_spec.rb; NOT run (the operator said no testing; no Rails or database in the
# sandbox that wrote it). Releases are built with `save!(validate: false)` because the repo has no
# release factory and a real upload needs an APK fixture; that helper is itself unrun.
RSpec.describe 'API release of a held release', type: :request do
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

  def make_release(target_channel, status:)
    release = target_channel.releases.build(release_version: '1.0.0', build_version: '1', status: status)
    release.save!(validate: false)
    release
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def release_it(release, secret: nil, **params)
    post "/api/releases/#{release.id}/release", params: params, headers: secret ? bearer(secret) : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }
  let(:held) { make_release(channel, status: 'held') }

  it 'refuses a request with no credential' do
    release_it(held)

    expect(response).to have_http_status(:unauthorized)
    expect(held.reload.status).to eq('held')
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    release_it(held, secret: "#{AppApiToken::PREFIX}wrong", token: owner.token)

    expect(response).to have_http_status(:unauthorized)
    expect(held.reload.status).to eq('held')
  end

  it 'refuses another app\'s release with a valid token (403)' do
    other_held = make_release(other_channel, status: 'held')

    release_it(other_held, secret: issued.secret)

    expect(response).to have_http_status(:forbidden)
    expect(other_held.reload.status).to eq('held')
  end

  it 'releases a held release with the app token' do
    release_it(held, secret: issued.secret)

    expect(response).to have_http_status(:ok)
    expect(held.reload.status).to eq('available')
  end

  it 'releases a held release with the user token' do
    release_it(held, token: owner.token)

    expect(response).to have_http_status(:ok)
    expect(held.reload.status).to eq('available')
  end

  %w[available halted pulled].each do |status|
    it "refuses a #{status} release (only held can be released this way)" do
      other = make_release(channel, status: status)

      release_it(other, secret: issued.secret)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(other.reload.status).to eq(status)
    end
  end

  it 'does not let an app token reach update or destroy (still user-token only)' do
    put "/api/releases/#{held.id}", params: { changelog: 'x' }, headers: bearer(issued.secret)
    expect(response).to have_http_status(:unauthorized)

    delete "/api/releases/#{held.id}", headers: bearer(issued.secret)
    expect(response).to have_http_status(:unauthorized)
    expect(Release.exists?(held.id)).to be(true)
  end

  it 'refuses a revoked token' do
    issued.token.revoke!

    release_it(held, secret: issued.secret)

    expect(response).to have_http_status(:unauthorized)
    expect(held.reload.status).to eq('held')
  end
end
