# frozen_string_literal: true

require 'rails_helper'

# Task 40b: the workflow_dispatch call to the storage repo. No network: a fake transport records the request.
# NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe CiCompileDispatcher do
  let(:app) { instance_double(App, name: 'Storeapp') }
  let(:release) do
    instance_double(Release, id: 345, file_storage_key: 'uploads/apps/a12/r345/binary/app.aab', app: app,
                             release_version: '1.1.4', build_version: '218')
  end
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
    { 'CI_COMPILE_DISPATCH_TOKEN' => 'dispatch-secret', 'GITHUB_STORAGE_REPO' => 'acme/storage' }
  end

  subject(:dispatcher) { described_class.new(release, transport: transport, env: env) }

  before { allow(ReleaseStorage).to receive(:adapter_name).and_return('github') }

  it 'posts one workflow_dispatch with the release id, tag, asset and artifact base, and no secret in the body' do
    expect(dispatcher.call).to be(true)

    expect(calls.size).to eq(1)
    call = calls.first
    expect(call[:method]).to eq(:post)
    expect(call[:url]).to eq(
      'https://api.github.com/repos/acme/storage/actions/workflows/compile-aab.yml/dispatches'
    )
    expect(call[:headers]['Authorization']).to eq('Bearer dispatch-secret')
    expect(JSON.parse(call[:body])).to eq(
      'ref' => 'main',
      'inputs' => { 'release_id' => '345', 'tag' => 'a12-r345', 'asset' => 'app.aab',
                    'artifact_base' => 'storeapp-1.1.4' }
    )
    expect(call[:body]).not_to include('dispatch-secret')
  end

  it 'prefers CI_COMPILE_REPO, CI_COMPILE_WORKFLOW, CI_COMPILE_REF and GITHUB_API_URL when set' do
    env.merge!('CI_COMPILE_REPO' => 'acme/ci', 'CI_COMPILE_WORKFLOW' => 'build.yaml', 'CI_COMPILE_REF' => 'trunk',
               'GITHUB_API_URL' => 'https://ghe.example.com/api/v3/')

    dispatcher.call

    expect(calls.first[:url]).to eq(
      'https://ghe.example.com/api/v3/repos/acme/ci/actions/workflows/build.yaml/dispatches'
    )
    expect(JSON.parse(calls.first[:body])['ref']).to eq('trunk')
  end

  describe 'refusing before any call is made' do
    def expect_refusal(message)
      expect { dispatcher.call }.to raise_error(described_class::DispatchError, message)
      expect(calls).to be_empty
    end

    it('without a dispatch token') do
      env.delete('CI_COMPILE_DISPATCH_TOKEN')
      expect_refusal(/CI_COMPILE_DISPATCH_TOKEN is not set/)
    end

    it('without a repo') do
      env.delete('GITHUB_STORAGE_REPO')
      expect_refusal(/CI_COMPILE_REPO/)
    end

    it('with a malformed repo') do
      env['CI_COMPILE_REPO'] = 'not a repo'
      expect_refusal(/owner\/name/)
    end

    it('with a workflow name that is not a file name (no path tricks)') do
      env['CI_COMPILE_WORKFLOW'] = '../../evil.yml'
      expect_refusal(/CI_COMPILE_WORKFLOW/)
    end

    it('when the file is not in storage') do
      allow(release).to receive(:file_storage_key).and_return(nil)
      expect_refusal(/not in storage/)
    end

    it('when the key does not follow the storage convention') do
      allow(release).to receive(:file_storage_key).and_return('somewhere/else.aab')
      expect_refusal(/cannot store key/)
    end

    it('when the storage adapter is not github') do
      allow(ReleaseStorage).to receive(:adapter_name).and_return('r2')
      expect_refusal(/RELEASE_STORAGE_ADAPTER=github/)
    end
  end

  describe 'when GitHub refuses' do
    {
      401 => /token is wrong/, 403 => /Actions: read and write/, 404 => /not found/,
      422 => /workflow_dispatch trigger/
    }.each do |status, hint|
      it "explains an HTTP #{status}" do
        refusal = ReleaseStorage::GithubAdapter::Response.new(status: status, headers: {},
                                                              body: '{"message":"nope"}')
        allow(transport).to receive(:call).and_return(refusal)

        pattern = /HTTP #{status}: nope.*#{hint.source}/m
        expect { dispatcher.call }.to raise_error(described_class::DispatchError, pattern)
      end
    end

    # Task 41c: a workflow copy older than 41c does not declare the input and GitHub refuses the whole dispatch.
    describe 'a workflow that does not declare artifact_base (Task 41c)' do
      let(:unexpected) do
        ReleaseStorage::GithubAdapter::Response.new(
          status: 422, headers: {}, body: '{"message":"Unexpected inputs provided: [\\"artifact_base\\"]"}'
        )
      end

      def replies(*list)
        queue = list.dup
        recorded = calls
        allow(transport).to receive(:call) do |method, url, headers: {}, body: nil, **|
          recorded << { method: method, url: url, headers: headers, body: body }
          queue.shift
        end
      end

      it 'repeats the dispatch once without the input' do
        replies(unexpected, response)

        expect(dispatcher.call).to be(true)
        expect(calls.size).to eq(2)
        expect(JSON.parse(calls.first[:body])['inputs']).to include('artifact_base' => 'storeapp-1.1.4')
        expect(JSON.parse(calls.last[:body])['inputs'])
          .to eq('release_id' => '345', 'tag' => 'a12-r345', 'asset' => 'app.aab')
      end

      it 'does not repeat it more than once' do
        replies(unexpected, unexpected)

        expect { dispatcher.call }.to raise_error(described_class::DispatchError, /HTTP 422/)
        expect(calls.size).to eq(2)
      end

      it 'does not repeat a 422 about something else' do
        replies(ReleaseStorage::GithubAdapter::Response.new(status: 422, headers: {},
                                                            body: '{"message":"No ref found for: nope"}'))

        expect { dispatcher.call }.to raise_error(described_class::DispatchError, /No ref found/)
        expect(calls.size).to eq(1)
      end
    end

    it 'never puts the token in the message' do
      refusal = ReleaseStorage::GithubAdapter::Response.new(status: 401, headers: {}, body: 'dispatch-secret')
      allow(transport).to receive(:call).and_return(refusal)

      expect { dispatcher.call }.to raise_error(described_class::DispatchError) { |e|
        expect(e.message).not_to include('dispatch-secret')
      }
    end

    it 'turns a network error into a DispatchError' do
      allow(transport).to receive(:call).and_raise(Errno::ECONNRESET)

      expect { dispatcher.call }.to raise_error(described_class::DispatchError, /could not be reached/)
    end
  end

  describe '.enabled?' do
    it 'is true only for the exact string "true"' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'true'))
      expect(described_class.enabled?).to be(true)

      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => '1'))
      expect(described_class.enabled?).to be(false)
    end
  end
end
