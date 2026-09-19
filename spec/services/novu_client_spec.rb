# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NovuClient do
  let(:requests) { [] }

  def stub_novu(status:, body:)
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/events/trigger') do |env|
        # env is reused for the response, so copy what we assert on now
        requests << { body: env.body, headers: env.request_headers.dup }
        [status, { 'Content-Type' => 'application/json' }, body.is_a?(String) ? body : JSON.generate(body)]
      end
    end
    # Keep NovuClient's real url/headers, only swap the network adapter.
    allow(Faraday).to receive(:new).and_wrap_original do |original, **options|
      original.call(**options) { |f| f.adapter :test, stubs }
    end
  end

  before do
    stub_const('ENV', ENV.to_hash.merge('NOVU_API_KEY' => 'secret-key'))
  end

  def trigger
    described_class.trigger(workflow_id: 'zealot-notice', to: { subscriberId: 'zealot-1', email: 'a@b.co' },
                            payload: { subject: 'Hi' }, transaction_id: 'tx-1')
  end

  it 'triggers the workflow and returns the transaction' do
    stub_novu(status: 201, body: { data: { acknowledged: true, status: 'processed', transactionId: 'tx-1' } })

    result = trigger

    expect(result.transaction_id).to eq('tx-1')
    expect(requests.first[:headers]['Authorization']).to eq('ApiKey secret-key')
    body = JSON.parse(requests.first[:body])
    expect(body).to include('name' => 'zealot-notice', 'transactionId' => 'tx-1',
                            'to' => { 'subscriberId' => 'zealot-1', 'email' => 'a@b.co' },
                            'payload' => { 'subject' => 'Hi' })
  end

  it 'accepts the un-enveloped response shape too' do
    stub_novu(status: 201, body: { acknowledged: true, status: 'processed', transactionId: 'tx-2' })

    expect(trigger.transaction_id).to eq('tx-2')
  end

  it 'raises a permanent error when Novu accepts but does not process the trigger' do
    stub_novu(status: 201, body: { data: { acknowledged: true, status: 'no_workflow_active_steps_defined' } })

    expect { trigger }.to raise_error(NovuClient::PermanentError, /no_workflow_active_steps_defined/)
  end

  it 'treats 401 and 404 as permanent' do
    stub_novu(status: 401, body: { message: 'Unauthorized' })
    expect { trigger }.to raise_error(NovuClient::PermanentError, /401.*Unauthorized/)

    stub_novu(status: 404, body: { message: ['Workflow not found'] })
    expect { trigger }.to raise_error(NovuClient::PermanentError, /404.*Workflow not found/)
  end

  it 'treats 429 and 5xx as temporary' do
    stub_novu(status: 429, body: 'API rate limit exceeded')
    expect { trigger }.to raise_error(NovuClient::TemporaryError)

    stub_novu(status: 503, body: 'Please wait some time, then try again.')
    expect { trigger }.to raise_error(NovuClient::TemporaryError)
  end

  it 'treats network failures as temporary' do
    connection = instance_double(Faraday::Connection)
    allow(connection).to receive(:post).and_raise(Faraday::ConnectionFailed, 'boom')
    allow(described_class).to receive(:connection).and_return(connection)

    expect { trigger }.to raise_error(NovuClient::TemporaryError, /ConnectionFailed/)
  end

  it 'refuses to run without an API key' do
    stub_const('ENV', ENV.to_hash.except('NOVU_API_KEY'))

    expect { trigger }.to raise_error(NovuClient::PermanentError, /NOVU_API_KEY/)
  end

  describe '.api_url' do
    it 'defaults to Novu cloud and honours NOVU_API_URL without a trailing slash' do
      expect(described_class.api_url).to eq('https://api.novu.co')

      stub_const('ENV', ENV.to_hash.merge('NOVU_API_URL' => 'https://eu.api.novu.co/'))
      expect(described_class.api_url).to eq('https://eu.api.novu.co')
    end
  end
end
