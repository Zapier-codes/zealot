# frozen_string_literal: true

require 'rails_helper'

# Task 34d-2 (D-Store leaf 36, `7.a.xi.zo`): create, list and revoke an app's per-app API tokens over the API,
# user token in the Authorization header only. A per-app token can never open this door (decision 34-4).
# Written by imitating api_listing_edit_spec.rb; NOT run (the operator said no testing).
RSpec.describe 'API app tokens', type: :request do
  let(:password) { 'correct-horse-9' }

  def make_user(email, role = :developer)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap do |user|
      user.update!(role: role)
    end
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:owner) { make_user('owner@example.com') }
  let!(:stranger) { make_user('stranger@example.com') }
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def as(user)
    bearer(user.token)
  end

  def tokens_path(target = app)
    "/api/apps/#{target.id}/api_tokens"
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  describe 'who may call' do
    it 'refuses every action with no credential' do
      get tokens_path
      expect(response).to have_http_status(:unauthorized)
      post tokens_path, params: { name: 'ci' }
      expect(response).to have_http_status(:unauthorized)
      delete "#{tokens_path}/1"
      expect(response).to have_http_status(:unauthorized)
      expect(AppApiToken.count).to eq(0)
    end

    it 'does not read the user token from the query string or the body' do
      get tokens_path, params: { token: owner.token }
      expect(response).to have_http_status(:unauthorized)
      post tokens_path, params: { token: owner.token, name: 'ci' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a per-app token on every action, even its own app\'s (decision 34-4)' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)
      headers = bearer(issued.secret)

      get tokens_path, headers: headers
      expect(response).to have_http_status(:unauthorized)
      post tokens_path, params: { name: 'more' }, headers: headers
      expect(response).to have_http_status(:unauthorized)
      delete "#{tokens_path}/#{issued.token.id}", headers: headers
      expect(response).to have_http_status(:unauthorized)
      expect(issued.token.reload.revoked_at).to be_nil
      expect(app.api_tokens.count).to eq(1)
    end

    it 'refuses a locked user' do
      owner.update!(locked_at: Time.current)
      get tokens_path, headers: as(owner)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a user who cannot manage the app (403) and mints nothing' do
      post tokens_path, params: { name: 'ci' }, headers: as(stranger)
      expect(response).to have_http_status(:forbidden)
      get tokens_path, headers: as(stranger)
      expect(response).to have_http_status(:forbidden)
      expect(AppApiToken.count).to eq(0)
    end

    it 'answers an unknown app with 404' do
      get '/api/apps/0/api_tokens', headers: as(admin)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/apps/:app_id/api_tokens' do
    it 'issues a token under the caller, returns the secret once and the row without it' do
      post tokens_path, params: { name: ' GitHub Actions ', expiry: '30' }, headers: as(admin)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body['secret']).to match(AppApiToken::SECRET_FORMAT)
      expect(body['name']).to eq('GitHub Actions')
      expect(body['scopes']).to eq(['publish'])
      expect(body['live']).to be(true)
      expect(body['last_four']).to eq(body['secret'][-4..])
      token = AppApiToken.find(body['id'])
      expect(token.created_by).to eq(admin)
      expect(token.app).to eq(app)
      expect(token.token_digest).to eq(AppApiToken.digest_for(body['secret']))
      expect(token.expires_at).to be_within(1.minute).of(30.days.from_now)
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'defaults the expiry to 90 days and accepts none' do
      post tokens_path, params: { name: 'a' }, headers: as(owner)
      expect(AppApiToken.last.expires_at).to be_within(1.minute).of(90.days.from_now)

      post tokens_path, params: { name: 'b', expiry: 'none' }, headers: as(owner)
      expect(AppApiToken.last.expires_at).to be_nil
    end

    it 'works for an app owner who is not an admin' do
      post tokens_path, params: { name: 'ci' }, headers: as(owner)
      expect(response).to have_http_status(:created)
      expect(AppApiToken.last.created_by).to eq(owner)
    end

    it 'the minted token authenticates as its creator on the app and on no other' do
      post tokens_path, params: { name: 'ci' }, headers: as(owner)
      secret = response.parsed_body['secret']
      scheme = app.schemes.create!(name: 'Scheme')
      channel = scheme.channels.create!(name: 'Android', device_type: :android)

      patch "/api/channels/#{channel.id}", params: { track: 'internal' }, headers: bearer(secret)
      expect(response).to have_http_status(:ok)

      other_channel = other_app.schemes.create!(name: 'S').channels.create!(name: 'A', device_type: :android)
      patch "/api/channels/#{other_channel.id}", params: { track: 'internal' }, headers: bearer(secret)
      expect(response).to have_http_status(:forbidden)
    end

    it 'refuses a missing name, a name that is not text and an unknown expiry (422)' do
      post tokens_path, params: {}, headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      post tokens_path, params: { name: %w[a b] }, headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      post tokens_path, params: { name: 'ci', expiry: '7' }, headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(AppApiToken.count).to eq(0)
    end

    it 'refuses a blank name and a name over the limit with the model\'s messages (422)' do
      post tokens_path, params: { name: '   ' }, headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['entry']).to have_key('name')

      post tokens_path, params: { name: 'x' * (AppApiToken::NAME_MAX_LENGTH + 1) }, headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses the eleventh live token (422)' do
      AppApiToken::MAX_LIVE_PER_APP.times { |i| AppApiToken.issue!(app: app, name: "t#{i}", created_by: owner) }

      post tokens_path, params: { name: 'one too many' }, headers: as(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(app.api_tokens.count).to eq(AppApiToken::MAX_LIVE_PER_APP)
    end

    it 'refuses an archived app' do
      app.update!(archived: true)
      post tokens_path, params: { name: 'ci' }, headers: as(admin)
      expect(response).to have_http_status(:bad_request)
      expect(AppApiToken.count).to eq(0)
    end
  end

  describe 'GET /api/apps/:app_id/api_tokens' do
    it 'lists the app\'s tokens newest first, never a secret or a digest' do
      older = AppApiToken.issue!(app: app, name: 'older', created_by: owner)
      newer = AppApiToken.issue!(app: app, name: 'newer', created_by: owner)
      AppApiToken.issue!(app: other_app, name: 'elsewhere', created_by: admin)
      older.token.revoke!

      get tokens_path, headers: as(owner)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body['tokens'].map { |t| t['name'] }).to eq(%w[newer older])
      expect(body['tokens'].map { |t| t['live'] }).to eq([true, false])
      expect(body['live_count']).to eq(1)
      expect(body['max_live']).to eq(AppApiToken::MAX_LIVE_PER_APP)
      expect(response.body).not_to include(newer.secret)
      expect(response.body).not_to include(newer.token.token_digest)
      expect(body['tokens'].first.keys).not_to include('secret', 'token_digest')
    end
  end

  describe 'DELETE /api/apps/:app_id/api_tokens/:id' do
    it 'revokes the token (soft) and the token stops authenticating' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      delete "#{tokens_path}/#{issued.token.id}", headers: as(owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['live']).to be(false)
      expect(issued.token.reload.revoked_at).to be_present
      expect(AppApiToken.authenticate(issued.secret)).to be_nil
    end

    it 'is idempotent' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)
      2.times do
        delete "#{tokens_path}/#{issued.token.id}", headers: as(owner)
        expect(response).to have_http_status(:ok)
      end
    end

    it 'does not reach another app\'s token (404)' do
      elsewhere = AppApiToken.issue!(app: other_app, name: 'elsewhere', created_by: admin)

      delete "#{tokens_path}/#{elsewhere.token.id}", headers: as(owner)

      expect(response).to have_http_status(:not_found)
      expect(elsewhere.token.reload.revoked_at).to be_nil
    end

    it 'refuses a user who cannot manage the app (403)' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)
      delete "#{tokens_path}/#{issued.token.id}", headers: as(stranger)
      expect(response).to have_http_status(:forbidden)
      expect(issued.token.reload.revoked_at).to be_nil
    end
  end
end
