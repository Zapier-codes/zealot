# frozen_string_literal: true

require 'rails_helper'

# Task 34a-7 (Storeapp leaf `f.xiv`): GET/POST /apps/:app_id/api_tokens and DELETE .../:id, the owner's
# screen for per-app API tokens. Written by imitating listing_text_spec.rb; NOT run (the operator said no
# testing). Checks who may use the page, that the secret is shown once and never stored, the expiry choices,
# the 10-live-token cap and revoking.
RSpec.describe 'API tokens page', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def create_token(name: 'ci', expiry: nil)
    post app_api_tokens_path(app), params: { api_token: { name: name, expiry: expiry }.compact }
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Token app') }

  before do
    Zealot::TenantRegistry.reset!
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  context 'as the app owner' do
    before { sign_in owner }

    it 'lists the tokens and shows the create form' do
      get app_api_tokens_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('apps.api_tokens.index.create'))
    end

    it 'creates a token, shows the secret once, and stores only its digest' do
      create_token(name: 'GitHub Actions')

      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to include('no-store')
      token = app.api_tokens.last
      secret = response.body[/zpa_[A-Za-z0-9_-]{43}/]
      expect(secret).to be_present
      expect(AppApiToken.authenticate(secret)).to eq(token)
      expect(token.created_by).to eq(owner)
      expect(token.token_digest).not_to include(secret)

      get app_api_tokens_path(app)
      expect(response.body).not_to include(secret)
      expect(response.body).to include("zpa_…#{token.last_four}")
    end

    it 'defaults the expiry to 90 days and honours 30, 365 and none' do
      create_token(name: 'default')
      expect(app.api_tokens.find_by(name: 'default').expires_at).to be_within(1.minute).of(90.days.from_now)

      create_token(name: 'short', expiry: '30')
      expect(app.api_tokens.find_by(name: 'short').expires_at).to be_within(1.minute).of(30.days.from_now)

      create_token(name: 'long', expiry: '365')
      expect(app.api_tokens.find_by(name: 'long').expires_at).to be_within(1.minute).of(365.days.from_now)

      create_token(name: 'forever', expiry: 'none')
      expect(app.api_tokens.find_by(name: 'forever').expires_at).to be_nil
    end

    it 'answers 400 for an unknown expiry and creates nothing' do
      create_token(name: 'odd', expiry: '7')

      expect(response).to have_http_status(:bad_request)
      expect(app.api_tokens).to be_empty
    end

    it 'answers 422 for a blank name and creates nothing' do
      create_token(name: '   ')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(app.api_tokens).to be_empty
    end

    it 'refuses the 11th live token with a reason, and a revoked token frees a place' do
      AppApiToken::MAX_LIVE_PER_APP.times { |i| AppApiToken.issue!(app: app, name: "t#{i}", created_by: owner) }

      create_token(name: 'one too many')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(app.api_tokens.count).to eq(AppApiToken::MAX_LIVE_PER_APP)

      app.api_tokens.first.revoke!
      create_token(name: 'fits now')
      expect(response).to have_http_status(:ok)
    end

    it 'revokes a token so it no longer authenticates' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      delete app_api_token_path(app, issued.token)

      expect(response).to redirect_to(app_api_tokens_path(app))
      expect(issued.token.reload.revoked_at).to be_present
      expect(AppApiToken.authenticate(issued.secret)).to be_nil
    end

    it 'cannot revoke another app\'s token through this app\'s URL' do
      other_app = create(:app, name: 'Other')
      other_app.create_owner(owner)
      issued = AppApiToken.issue!(app: other_app, name: 'ci', created_by: owner)

      delete app_api_token_path(app, issued.token)

      expect(response).to have_http_status(:not_found)
      expect(issued.token.reload.revoked_at).to be_nil
    end
  end

  context 'as an admin' do
    before { sign_in admin }

    it 'may create a token' do
      create_token

      expect(response).to have_http_status(:ok)
      expect(app.api_tokens.count).to eq(1)
    end
  end

  context 'as a plain member of the app' do
    before { sign_in teammate }

    it 'is refused every action' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      get app_api_tokens_path(app)
      expect(response).not_to have_http_status(:ok)
      create_token(name: 'nope')
      expect(response).not_to have_http_status(:ok)
      delete app_api_token_path(app, issued.token)
      expect(response).not_to have_http_status(:ok)
      expect(issued.token.reload.revoked_at).to be_nil
      expect(app.api_tokens.count).to eq(1)
    end
  end

  context 'as someone with no access to the app' do
    before { sign_in stranger }

    it 'is refused' do
      get app_api_tokens_path(app)
      expect(response).not_to have_http_status(:ok)

      create_token(name: 'nope')
      expect(app.api_tokens).to be_empty
    end
  end

  context 'with no session' do
    it 'does not open the page, even with a valid app token in the header' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      get app_api_tokens_path(app), headers: { 'Authorization' => "Bearer #{issued.secret}" }

      expect(response).not_to have_http_status(:ok)
      post app_api_tokens_path(app), params: { api_token: { name: 'x' } },
                                     headers: { 'Authorization' => "Bearer #{issued.secret}" }
      expect(app.api_tokens.count).to eq(1)
    end
  end
end
