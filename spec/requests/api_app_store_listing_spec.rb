# frozen_string_literal: true

require 'rails_helper'

# Task 42e: the store listing, the owner and the editorial flags over the API. Written by imitating
# api_release_retry_compile_spec.rb; NOT run (no Postgres or gems in the sandbox that wrote it), so look here
# first if CI is red for this slice. User token only, in `params[:token]` (the legacy door answers 422, not
# 401, for a missing or wrong token: Api::BaseController#render_unauthorized_user_key).
RSpec.describe 'API store listing, owner and editorial', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Listing App') }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  def as(user, extra = {})
    { token: user.token }.merge(extra)
  end

  def make_profile(user)
    PublisherProfile.create!(user: user, kind: 'company', display_name: 'Acme', legal_name: 'Acme Ltd',
                             country: 'Germany', contact_email: user.email)
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }
  let!(:other) { make_user('other@example.com', :developer) }

  before do
    Zealot::TenantRegistry.reset!
    allow(CatalogIndexPublishJob).to receive(:perform_later)
    app.collaborators.where(owner: true).destroy_all
    app.create_owner(developer)
  end

  describe 'GET store_listing' do
    it 'refuses a request with no token' do
      get "/api/apps/#{app.id}/store_listing"

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses a user who is neither the owner nor an admin' do
      get "/api/apps/#{app.id}/store_listing", params: as(other)

      expect(response).to have_http_status(:forbidden)
    end

    it 'reports the owner, the status and what keeps the app out of the index' do
      get "/api/apps/#{app.id}/store_listing", params: as(admin)

      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body['owner']['email']).to eq('dev@example.com')
      expect(body['listing_status']).to eq('draft')
      expect(body['eligible_for_catalog_index']).to be(false)
      expect(body['blockers'].join(' ')).to include('only live apps are indexed')
      expect(body['blockers'].join(' ')).to include('no release has status available')
    end

    it 'answers 404 for an app that does not exist' do
      get '/api/apps/0/store_listing', params: as(admin)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST store_listing (request listing)' do
    it 'is refused for a user who does not own the app' do
      post "/api/apps/#{app.id}/store_listing", params: as(other)

      expect(response).to have_http_status(:forbidden)
      expect(app.reload.listing_status).to eq('draft')
    end

    it 'says so when the owner has no publisher profile' do
      post "/api/apps/#{app.id}/store_listing", params: as(developer)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('publisher_profile_required')
      expect(app.reload.listing_status).to eq('draft')
    end

    it 'moves a draft to awaiting_payment, once' do
      make_profile(developer)

      post "/api/apps/#{app.id}/store_listing", params: as(developer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['listing_status']).to eq('awaiting_payment')
      expect(app.reload.publisher_profile).to be_present

      post "/api/apps/#{app.id}/store_listing", params: as(developer)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('listing_not_available')
    end
  end

  describe 'PATCH store_listing/mark_paid' do
    before { app.update!(listing_status: 'awaiting_payment') }

    it 'is refused for the owner who is not an admin' do
      patch "/api/apps/#{app.id}/store_listing/mark_paid", params: as(developer)

      expect(response).to have_http_status(:forbidden)
      expect(app.reload.listing_status).to eq('awaiting_payment')
    end

    it 'makes no Payment and no maintenance billing, so the app is outside every payment rule (Task 42h)' do
      patch "/api/apps/#{app.id}/store_listing/mark_paid", params: as(admin)

      expect(app.reload).to be_listing_live
      expect(Payment.where(app_id: app.id)).to be_empty
      expect(AppMaintenanceBilling.where(app_id: app.id)).to be_empty
    end

    it 'puts the listing live for an admin and sets listed_at' do
      patch "/api/apps/#{app.id}/store_listing/mark_paid", params: as(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['listing_status']).to eq('live')
      expect(app.reload.listed_at).to be_present
    end

    it 'refuses an app that is still a draft' do
      app.update!(listing_status: 'draft')

      patch "/api/apps/#{app.id}/store_listing/mark_paid", params: as(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('listing_not_available')
    end
  end

  describe 'PUT owner' do
    it 'is refused for a user who is neither the owner nor an admin' do
      put "/api/apps/#{app.id}/owner", params: as(other, user_id: other.id)

      expect(response).to have_http_status(:forbidden)
      expect(app.reload.owner.user).to eq(developer)
    end

    it 'lets an admin hand the app to another user, by id or by email' do
      put "/api/apps/#{app.id}/owner", params: as(admin, email: 'OTHER@example.com')

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['changed']).to be(true)
      expect(app.reload.owner.user).to eq(other)

      put "/api/apps/#{app.id}/owner", params: as(admin, user_id: developer.id)
      expect(app.reload.owner.user).to eq(developer)
    end

    it 'removes the new owner’s earlier collaborator row instead of leaving two' do
      app.collaborators.create!(user: other, role: Collaborator.roles[:developer])

      put "/api/apps/#{app.id}/owner", params: as(admin, user_id: other.id)

      expect(app.collaborators.where(user_id: other.id).count).to eq(1)
      expect(app.reload.owner.user).to eq(other)
    end

    it 'is idempotent for the current owner' do
      put "/api/apps/#{app.id}/owner", params: as(admin, user_id: developer.id)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['changed']).to be(false)
    end

    it 'answers 404 for an unknown user and 422 when no user is named' do
      put "/api/apps/#{app.id}/owner", params: as(admin, user_id: 0)
      expect(response).to have_http_status(:not_found)

      put "/api/apps/#{app.id}/owner", params: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'refuses an archived app' do
      app.update!(archived: true)

      put "/api/apps/#{app.id}/owner", params: as(admin, user_id: other.id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('app_archived')
    end
  end

  describe 'PUT editorial' do
    it 'is refused for the owner who is not an admin' do
      put "/api/apps/#{app.id}/editorial", params: as(developer, featured: 'true')

      expect(response).to have_http_status(:forbidden)
      expect(app.reload.featured).to be_falsey
    end

    it 'sets the flags to the values sent, and repeating it changes nothing more' do
      2.times do
        put "/api/apps/#{app.id}/editorial", params: as(admin, featured: 'true', editors_pick: 'false')

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('featured' => true, 'editors_pick' => false)
      end
      expect(app.reload.featured).to be(true)
    end

    it 'refuses a call with no flag and a value that is not true or false' do
      put "/api/apps/#{app.id}/editorial", params: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)

      put "/api/apps/#{app.id}/editorial", params: as(admin, featured: 'maybe')
      expect(response).to have_http_status(:unprocessable_entity)
      expect(app.reload.featured).to be_falsey
    end
  end

  # Task 42f: pay from the API. B-PAY is stubbed at the client, as in hyperswitch_payment_spec.rb.
  describe 'POST store_listing/pay and GET store_listing/payment' do
    let(:started) do
      HyperswitchClient::Result.new(payment_id: 'pay_api_1', status: 'requires_payment_method', client_secret: 'secret_1')
    end

    before do
      app.update!(listing_status: 'awaiting_payment')
      allow(HyperswitchClient).to receive(:configured?).and_return(true)
      allow(HyperswitchClient).to receive(:create_payment).and_return(started)
      stub_const('ENV', ENV.to_hash.merge('HYPERSWITCH_PUBLISHABLE_KEY' => 'pk_test', 'HYPERSWITCH_SDK_URL' => 'sdk.example.com'))
    end

    it 'starts a pending listing-fee payment for the owner and returns what the checkout needs' do
      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer)

      body = response.parsed_body
      expect(response).to have_http_status(:created)
      expect(body).to include('status' => 'pending', 'amount_cents' => 1499, 'currency' => 'usd',
                              'list_price_cents' => 2500, 'client_secret' => 'secret_1',
                              'checkout_url' => a_string_including('/checkout/'),
                              'confirm_url' => a_string_including('/payments/pay_api_1/confirm'), 'publishable_key' => 'pk_test',
                              'sdk_url' => 'sdk.example.com', 'hyperswitch_payment_id' => 'pay_api_1')
      expect(app.payments.last).to have_attributes(purpose: 'listing_fee', status: 'pending', user_id: developer.id)
      expect(app.reload.listing_status).to eq('awaiting_payment') # only the webhook makes it live
    end

    it 'is owner-only, even for an admin' do
      post "/api/apps/#{app.id}/store_listing/pay", params: as(admin)

      expect(response).to have_http_status(:forbidden)
      expect(Payment.count).to eq(0)
    end

    it 'refuses an app that is not awaiting payment' do
      app.update!(listing_status: 'draft')

      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('listing_not_available')
      expect(Payment.count).to eq(0)
    end

    it 'answers 503 when B-PAY is not configured and creates nothing' do
      allow(HyperswitchClient).to receive(:configured?).and_return(false)

      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer)

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body['code']).to eq('payment_not_configured')
      expect(Payment.count).to eq(0)
    end

    it 'answers 502 and keeps the row as failed when B-PAY refuses' do
      allow(HyperswitchClient).to receive(:create_payment).and_raise(HyperswitchClient::PermanentError, 'bad key')

      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer)

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body['code']).to eq('payment_start_failed')
      expect(app.payments.last.status).to eq('failed')
    end

    it 'refuses a return_url that is not http or https' do
      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer, return_url: 'javascript:alert(1)')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('invalid_return_url')
      expect(Payment.count).to eq(0)
    end

    it 'passes a valid return_url on to B-PAY' do
      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer, return_url: 'https://example.com/done')

      expect(HyperswitchClient).to have_received(:create_payment).with(hash_including(return_url: 'https://example.com/done'))
    end

    it 'lists the listing-fee payments without secrets, and the report carries the latest one' do
      post "/api/apps/#{app.id}/store_listing/pay", params: as(developer)

      get "/api/apps/#{app.id}/store_listing/payment", params: as(developer)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['payments'].first).to include('status' => 'pending', 'amount_cents' => 1499)
      expect(response.body).not_to include('secret_1')

      get "/api/apps/#{app.id}/store_listing", params: as(admin)
      expect(response.parsed_body['latest_payment']).to include('status' => 'pending')
      expect(response.parsed_body['listing_fee'])
        .to eq('amount_cents' => 1499, 'list_price_cents' => 2500, 'currency' => 'usd')
    end

    it 'refuses the payment list to someone who is neither the owner nor an admin' do
      get "/api/apps/#{app.id}/store_listing/payment", params: as(other)

      expect(response).to have_http_status(:forbidden)
    end
  end
end
