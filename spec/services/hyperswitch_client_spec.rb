# frozen_string_literal: true

require 'rails_helper'

RSpec.describe HyperswitchClient do
  let(:requests) { [] }

  def stub_bpay(method:, path:, status:, body:)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.public_send(method, path) do |env|
        requests << { body: env.body, headers: env.request_headers.dup }
        [status, { 'Content-Type' => 'application/json' }, body.is_a?(String) ? body : JSON.generate(body)]
      end
    end
    allow(Faraday).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options) { |f| f.adapter :test, stubs }
    end
  end

  before do
    stub_const('ENV', ENV.to_hash.merge('HYPERSWITCH_API_KEY' => 'secret-key'))
  end

  describe '.create_payment' do
    it 'posts amount/currency/customer and sets the auth header' do
      stub_bpay(method: :post, path: '/payments', status: 200,
                body: { payment_id: 'pay_1', status: 'succeeded', mandate_id: 'mandate_1' })

      result = described_class.create_payment(
        amount_cents: 1499, currency: 'usd', customer_id: 'app-42',
        return_url: 'https://example.com/return', setup_future_usage: 'off_session'
      )

      expect(result.payment_id).to eq('pay_1')
      expect(result.mandate_id).to eq('mandate_1')
      expect(requests.first[:headers]['api-key']).to eq('secret-key')
      body = JSON.parse(requests.first[:body])
      expect(body).to include('amount' => 1499, 'currency' => 'USD', 'customer_id' => 'app-42',
                              'setup_future_usage' => 'off_session')
    end
  end

  describe '.charge_mandate' do
    it 'sends off_session + recurring_details for a stored mandate' do
      stub_bpay(method: :post, path: '/payments', status: 200,
                body: { payment_id: 'pay_2', status: 'succeeded' })

      described_class.charge_mandate(amount_cents: 200, currency: 'usd', customer_id: 'app-42',
                                     mandate_id: 'mandate_1')

      body = JSON.parse(requests.first[:body])
      expect(body).to include('off_session' => true,
                              'recurring_details' => { 'type' => 'mandate_id', 'data' => 'mandate_1' })
    end
  end

  it 'treats 429 and 5xx as temporary, everything else 4xx as permanent' do
    stub_bpay(method: :post, path: '/payments', status: 429, body: 'slow down')
    expect { described_class.create_payment(amount_cents: 100, currency: 'usd', customer_id: 'a',
                                            return_url: 'https://x') }
      .to raise_error(described_class::TemporaryError)

    stub_bpay(method: :post, path: '/payments', status: 422, body: { error: { message: 'bad card' } })
    expect { described_class.create_payment(amount_cents: 100, currency: 'usd', customer_id: 'a',
                                            return_url: 'https://x') }
      .to raise_error(described_class::PermanentError, /bad card/)
  end

  it 'refuses to run without an API key' do
    stub_const('ENV', ENV.to_hash.except('HYPERSWITCH_API_KEY'))

    expect { described_class.create_payment(amount_cents: 100, currency: 'usd', customer_id: 'a',
                                            return_url: 'https://x') }
      .to raise_error(described_class::PermanentError, /HYPERSWITCH_API_KEY/)
  end

  describe '.api_url' do
    it 'defaults to the confirmed B-PAY URL and honours HYPERSWITCH_API_URL without a trailing slash' do
      expect(described_class.api_url).to eq('https://b-pay-backend-new.onrender.com')

      stub_const('ENV', ENV.to_hash.merge('HYPERSWITCH_API_URL' => 'https://staging.example.com/'))
      expect(described_class.api_url).to eq('https://staging.example.com')
    end
  end
end
