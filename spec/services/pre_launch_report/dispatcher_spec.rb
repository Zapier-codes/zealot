# frozen_string_literal: true

require 'rails_helper'

# Z-P12: the workflow_dispatch call that asks CI to run the build on redroid. No network: a fake transport
# records the request. Mirrors spec/services/ci_compile_dispatcher_spec.rb.
RSpec.describe PreLaunchReport::Dispatcher do
  let(:release) { instance_double(Release, id: 345) }
  let(:response) { ReleaseStorage::GithubAdapter::Response.new(status: 204, headers: {}, body: '') }
  let(:calls) { [] }
  let(:transport) do
    recorded = calls
    reply = response
    Class.new do
      define_method(:call) do |method, url, headers: {}, body: nil, **|
        recorded << { method: method, url: url, headers: headers, body: body }
        reply
      end
    end.new
  end
  let(:env) do
    { 'PRE_LAUNCH_REPO' => 'acme/ci', 'PRE_LAUNCH_DISPATCH_TOKEN' => 'dispatch-secret' }
  end

  subject(:dispatcher) { described_class.new(release, transport: transport, env: env) }

  describe '.enabled?' do
    it 'is false with no repo or token' do
      expect(described_class.enabled?({})).to be(false)
      expect(described_class.enabled?({ 'PRE_LAUNCH_REPO' => 'acme/ci' })).to be(false)
      expect(described_class.enabled?({ 'PRE_LAUNCH_DISPATCH_TOKEN' => 't' })).to be(false)
    end

    it 'is true with both' do
      expect(described_class.enabled?(env)).to be(true)
    end
  end

  it 'posts one workflow_dispatch with the release id and no secret in the body' do
    expect(dispatcher.call).to be(true)

    expect(calls.size).to eq(1)
    call = calls.first
    expect(call[:method]).to eq(:post)
    expect(call[:url]).to eq('https://api.github.com/repos/acme/ci/actions/workflows/pre-launch-report.yml/dispatches')
    expect(call[:headers]['Authorization']).to eq('Bearer dispatch-secret')
    expect(JSON.parse(call[:body])).to eq('ref' => 'main', 'inputs' => { 'release_id' => '345' })
    expect(call[:body]).not_to include('dispatch-secret')
  end

  it 'honours the workflow, ref and API URL overrides' do
    env.merge!('PRE_LAUNCH_WORKFLOW' => 'run.yml', 'PRE_LAUNCH_REF' => 'trunk',
               'GITHUB_API_URL' => 'https://ghe.example.com/api/v3/')
    dispatcher.call
    expect(calls.first[:url]).to eq('https://ghe.example.com/api/v3/repos/acme/ci/actions/workflows/run.yml/dispatches')
    expect(JSON.parse(calls.first[:body])['ref']).to eq('trunk')
  end

  it 'refuses to dispatch with no repo' do
    env.delete('PRE_LAUNCH_REPO')
    expect { dispatcher.call }.to raise_error(described_class::DispatchError, /PRE_LAUNCH_REPO/)
  end

  it 'refuses to dispatch with no token' do
    env.delete('PRE_LAUNCH_DISPATCH_TOKEN')
    expect { dispatcher.call }.to raise_error(described_class::DispatchError, /PRE_LAUNCH_DISPATCH_TOKEN/)
  end

  it 'raises DispatchError on a non-204 answer' do
    allow(response).to receive(:status).and_return(401)
    expect { dispatcher.call }.to raise_error(described_class::DispatchError, /refused \(401\)/)
  end
end
