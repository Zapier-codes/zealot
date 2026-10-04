# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a. Written by reading the code, NOT run. A fake transport stands in for GitHub.
RSpec.describe ReleaseUploadDispatcher do
  Reply = Struct.new(:status, :body)

  let(:upload) { instance_double(ReleaseUpload, id: 7, staging_key: 'staging/a1/u7/abc/app.apk', filename: 'app.apk') }
  let(:env) do
    { 'CI_COMPILE_REPO' => 'acme/storage', 'CI_COMPILE_DISPATCH_TOKEN' => 'tok', 'CI_COMPILE_REF' => 'main' }
  end
  let(:transport) do
    Class.new do
      attr_reader :requests

      def initialize(reply)
        @reply = reply
        @requests = []
      end

      def call(method, url, headers: {}, body: nil, **)
        @requests << { method: method, url: url, headers: headers, body: body }
        @reply
      end
    end
  end

  def dispatcher(reply, **overrides)
    @transport = transport.new(reply)
    described_class.new(overrides.fetch(:upload, upload), transport: @transport, env: overrides.fetch(:env, env))
  end

  it 'posts a workflow_dispatch with the three inputs and no secret in the body' do
    expect(dispatcher(Reply.new(204, '')).call).to be(true)

    request = @transport.requests.first
    expect(request[:url]).to eq(
      'https://api.github.com/repos/acme/storage/actions/workflows/read-upload.yml/dispatches'
    )
    expect(JSON.parse(request[:body])).to eq(
      'ref' => 'main',
      'inputs' => { 'upload_id' => '7', 'staging_key' => 'staging/a1/u7/abc/app.apk', 'filename' => 'app.apk' }
    )
    expect(request[:body]).not_to include('tok')
    expect(request[:headers]['Authorization']).to eq('Bearer tok')
  end

  it 'refuses when the token or repo is missing, or the workflow name is not a file name' do
    expect { dispatcher(Reply.new(204, ''), env: env.except('CI_COMPILE_DISPATCH_TOKEN')).call }
      .to raise_error(described_class::DispatchError, /DISPATCH_TOKEN/)
    expect { dispatcher(Reply.new(204, ''), env: env.except('CI_COMPILE_REPO')).call }
      .to raise_error(described_class::DispatchError, /CI_COMPILE_REPO/)
    expect { dispatcher(Reply.new(204, ''), env: env.merge('CI_READ_UPLOAD_WORKFLOW' => '../x')).call }
      .to raise_error(described_class::DispatchError, /CI_READ_UPLOAD_WORKFLOW/)
  end

  it 'turns a GitHub refusal into a readable reason' do
    reply = Reply.new(422, JSON.generate('message' => 'Workflow does not have workflow_dispatch'))
    expect { dispatcher(reply).call }
      .to raise_error(described_class::DispatchError, /HTTP 422.*upload_id, staging_key and filename/m)
  end

  it 'refuses an upload with no staging key' do
    bare = instance_double(ReleaseUpload, id: 8, staging_key: nil, filename: 'x.apk')
    expect { dispatcher(Reply.new(204, ''), upload: bare).call }
      .to raise_error(described_class::DispatchError, /staging key/)
  end
end
