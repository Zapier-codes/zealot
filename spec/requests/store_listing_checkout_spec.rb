# frozen_string_literal: true

require 'rails_helper'

# Task 42i: the hosted card page reached from `checkout_url`. B-PAY is never called (the page only embeds its
# SDK in the browser). NOT run.
RSpec.describe 'Hosted store-listing checkout (Task 42i)', type: :request do
  let(:owner) do
    User.create!(email: 'payer@example.com', username: 'payer', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end
  let(:app_record) { App.create!(name: 'Checkout app') }
  let(:payment) do
    Payment.create!(app: app_record, user: owner, purpose: 'listing_fee', amount_cents: 1499, currency: 'usd',
                    status: 'pending', hyperswitch_payment_id: 'pay_c1', client_secret: 'secret_c1')
  end

  before do
    stub_const('ENV', ENV.to_hash.merge('HYPERSWITCH_PUBLISHABLE_KEY' => 'pk_test', 'HYPERSWITCH_SDK_URL' => 'sdk.example.com'))
  end

  it 'shows the card page with the struck-through $25 and the $14.99 for a pending payment, with no login' do
    get "/checkout/#{payment.checkout_token}"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('$14.99', '$25.00', 'secret_c1', 'sdk.example.com/HyperLoader.js')
  end

  it 'is a 404 for a bad token' do
    get '/checkout/not-a-real-token'
    expect(response).to have_http_status(:not_found)
  end

  it 'is a 404 once the link has expired' do
    token = payment.checkout_token
    travel_to(Payment::CHECKOUT_TTL.from_now + 1.minute) do
      get "/checkout/#{token}"
      expect(response).to have_http_status(:not_found)
    end
  end

  it 'does not accept a maintenance payment token' do
    other = Payment.create!(app: app_record, user: owner, purpose: 'maintenance', billing_period: 'monthly',
                            amount_cents: 200, currency: 'usd', status: 'pending', hyperswitch_payment_id: 'pay_c2')
    get "/checkout/#{other.checkout_token}"
    expect(response).to have_http_status(:not_found)
  end

  it 'shows no card form and no secret once the payment succeeded' do
    token = payment.checkout_token
    payment.mark_succeeded!(hyperswitch_payment_id: 'pay_c1')

    get "/checkout/#{token}"

    expect(response.body).to include('Payment received')
    expect(response.body).not_to include('secret_c1')
    expect(payment.reload.client_secret).to be_nil
  end
end
