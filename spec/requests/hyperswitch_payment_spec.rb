# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'B-PAY payment (Task 32)', type: :request do
  include Devise::Test::IntegrationHelpers

  def make_user(name)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end

  let(:owner) { make_user('owner') }
  let(:profile) do
    PublisherProfile.create!(user: owner, kind: :individual, display_name: 'Ada Labs',
                             legal_name: 'Ada Lovelace', country: 'Nigeria', contact_email: owner.email)
  end
  let(:app_record) do
    App.create!(name: 'Payable app').tap do |a|
      a.create_owner(owner)
      a.request_store_listing!(profile)
    end
  end

  describe 'POST /apps/:app_id/store_listing/pay' do
    it 'creates a pending Payment and starts a B-PAY checkout' do
      sign_in owner
      allow(HyperswitchClient).to receive(:create_payment)
        .and_return(HyperswitchClient::Result.new(payment_id: 'pay_1', status: 'requires_confirmation',
                                                   client_secret: 'secret_1', raw: {}))

      expect { post pay_app_store_listing_path(app_record) }.to change(Payment, :count).by(1)

      payment = Payment.last
      expect(payment.purpose).to eq('listing_fee')
      expect(payment.amount_cents).to eq(1499)
      expect(payment.status).to eq('pending')
      expect(payment.hyperswitch_payment_id).to eq('pay_1')
      expect(response).to have_http_status(:ok)
    end

    it 'refuses when the app is not awaiting payment' do
      sign_in owner
      draft = App.create!(name: 'Still draft').tap { |a| a.create_owner(owner) }

      expect { post pay_app_store_listing_path(draft) }.not_to change(Payment, :count)
      expect(response).to redirect_to(app_store_listing_path(draft))
    end

    it 'is owner-only' do
      sign_in make_user('stranger')

      post pay_app_store_listing_path(app_record)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /hooks/hyperswitch' do
    let(:payment) do
      Payment.create!(app: app_record, user: owner, purpose: 'listing_fee', amount_cents: 1499,
                      currency: 'usd', status: 'pending', hyperswitch_payment_id: 'pay_1')
    end
    let(:secret) { 'whsec_test' }

    def signed_post(body)
      raw = body.to_json
      signature = OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
      post '/hooks/hyperswitch', params: raw, headers: { 'Content-Type' => 'application/json',
                                                          'X-Webhook-Signature' => signature }
    end

    before { stub_const('ENV', ENV.to_hash.merge('HYPERSWITCH_WEBHOOK_SECRET' => secret)) }

    it 'rejects a request with a missing or wrong signature' do
      post '/hooks/hyperswitch', params: { event_type: 'payment_succeeded' }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:unauthorized)
    end

    it 'marks the Payment succeeded AND calls App#go_live! for a listing_fee payment' do
      payment
      expect(app_record).to be_listing_awaiting_payment

      signed_post(event_type: 'payment_succeeded', content: { payment_id: 'pay_1', mandate_id: 'mandate_1' })

      expect(response).to have_http_status(:ok)
      expect(payment.reload).to be_succeeded
      expect(payment.hyperswitch_mandate_id).to eq('mandate_1')
      expect(app_record.reload).to be_listing_live
      expect(app_record.listed_at).to be_present
    end

    it 'does not call go_live! for a maintenance payment' do
      app_record.go_live! # already live before the maintenance cycle runs
      maintenance = Payment.create!(app: app_record, user: owner, purpose: 'maintenance',
                                    billing_period: 'monthly', amount_cents: 200, currency: 'usd',
                                    status: 'pending', hyperswitch_payment_id: 'pay_2')

      signed_post(event_type: 'payment_succeeded', content: { payment_id: 'pay_2' })

      expect(maintenance.reload).to be_succeeded
      expect(app_record.reload).to be_listing_live # unchanged, not re-triggered
    end

    it 'marks the Payment failed on a payment_failed event, leaving the app awaiting_payment' do
      payment
      signed_post(event_type: 'payment_failed', content: { payment_id: 'pay_1' })

      expect(response).to have_http_status(:ok)
      expect(payment.reload.status).to eq('failed')
      expect(app_record.reload).to be_listing_awaiting_payment
    end

    it 'is a no-op (still 200s) for an event with no matching Payment' do
      signed_post(event_type: 'payment_succeeded', content: { payment_id: 'pay_unknown' })

      expect(response).to have_http_status(:ok)
    end
  end
end
