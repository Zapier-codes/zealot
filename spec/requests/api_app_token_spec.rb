# frozen_string_literal: true

require 'rails_helper'

# Task 34a-2 (Storeapp leaf `f.xiv`): the `/api` accepts a per-app token, header only, for its own app,
# acting as its creator. The proof endpoint is the read-only GET /api/apps/versions. Written by
# imitating api_tenant_spec.rb; NOT run (no Ruby, Rails or database in the sandbox that wrote it), so
# it is the first thing to look at if CI is red for this slice.
RSpec.describe 'API per-app token', type: :request do
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

  def versions(channel_key:, secret: nil, **params)
    get '/api/apps/versions', params: { channel_key: channel_key }.merge(params),
                              headers: secret ? bearer(secret) : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  it 'is unchanged without a bearer header: the channel key alone still answers' do
    versions(channel_key: channel.key)

    expect(response).to have_http_status(:ok)
  end

  it 'answers 200 for a read of the token\'s own app' do
    versions(channel_key: channel.key, secret: issued.secret)

    expect(response).to have_http_status(:ok)
  end

  it 'stamps last_used_at on use' do
    expect { versions(channel_key: channel.key, secret: issued.secret) }
      .to change { issued.token.reload.last_used_at }.from(nil)
  end

  it 'answers 403 for another app\'s channel' do
    versions(channel_key: other_channel.key, secret: issued.secret)

    expect(response).to have_http_status(:forbidden)
  end

  describe '401, one generic answer, never saying which check failed' do
    def expect_unauthorized
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['WWW-Authenticate']).to eq('Bearer')
      expect(JSON.parse(response.body)).to eq('error' => I18n.t('api.unauthorized_app_token'))
    end

    it 'for a wrong secret' do
      versions(channel_key: channel.key, secret: AppApiToken.generate_secret)

      expect_unauthorized
    end

    it 'for a revoked token' do
      secret = issued.secret
      issued.token.revoke!
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'for an expired token' do
      secret = issued.secret
      issued.token.update_columns(expires_at: 1.minute.ago)
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'for a token that carries no publish scope' do
      secret = issued.secret
      issued.token.update_columns(scopes: [])
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'for a creator who is locked' do
      secret = issued.secret
      owner.lock_access!
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'for a creator who lost access to the app' do
      secret = issued.secret
      Collaborator.where(user: owner, app: app).destroy_all
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'for a token whose creator was deleted' do
      secret = issued.secret
      owner.destroy!
      versions(channel_key: channel.key, secret: secret)

      expect_unauthorized
    end

    it 'does not fall back to the channel key when the token is bad' do
      versions(channel_key: channel.key, secret: AppApiToken.generate_secret)

      expect(response).not_to have_http_status(:ok)
    end
  end

  it 'never reads ?token=: a zpa_ secret in the query string does not authenticate as a token' do
    versions(channel_key: channel.key, token: issued.secret)

    # No header, so this is the unchanged channel-key path. The query value is ignored: it is not
    # treated as a token (no use is recorded) and it is not refused either.
    expect(response).to have_http_status(:ok)
    expect(issued.token.reload.last_used_at).to be_nil
  end

  it 'ignores an Authorization header that is not an app token (no zpa_ prefix)' do
    versions(channel_key: channel.key, secret: 'not-a-zealot-token')

    expect(response).to have_http_status(:ok)
  end

  context 'on a tenant\'s host' do
    let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
    let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
    let!(:acme_channel) { make_channel(acme_app) }

    before { host! 'store.acme.example.com' }

    it 'answers 401 when the creator is not a member of that tenant' do
      acme_app.create_owner(owner)
      secret = AppApiToken.issue!(app: acme_app, name: 'ci', created_by: owner).secret
      versions(channel_key: acme_channel.key, secret: secret)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'answers 200 for a member creator on their own tenant\'s app' do
      acme_app.create_owner(owner)
      TenantMembership.create!(tenant: acme, user: owner, role: 'owner')
      secret = AppApiToken.issue!(app: acme_app, name: 'ci', created_by: owner).secret
      versions(channel_key: acme_channel.key, secret: secret)

      expect(response).to have_http_status(:ok)
    end

    it 'answers 401 for a token of an app that belongs to another host\'s tenant' do
      TenantMembership.create!(tenant: acme, user: owner, role: 'owner')
      versions(channel_key: channel.key, secret: issued.secret)

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
