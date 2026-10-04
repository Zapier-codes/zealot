# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a: the stage-1 callback door. Authentication is the GitHub OIDC token; the verifier is stubbed here
# (its own spec signs real tokens). Needs Postgres. NOT run.
RSpec.describe 'Api::ReleaseUploadCallbacks', type: :request do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.apk', declared_size: 2048).tap do |row|
      row.update_columns(state: 'uploaded', uploaded_size: 2048)
    end
  end
  let(:body) do
    { state: 'ok', kind: 'apk', package_name: 'com.example.app', version_code: 3, version_name: '1.0',
      file_sha256: 'a' * 64, file_size: 2048, abis: ['arm64-v8a'] }
  end
  let(:env) { { 'CI_OIDC_AUDIENCE' => 'https://zealot.example', 'CI_COMPILE_REPO' => 'acme/storage' } }
  let(:verifier) { instance_double(GithubOidcVerifier) }

  before do
    stub_const('ENV', ENV.to_h.merge(env))
    allow(GithubOidcVerifier).to receive(:new).and_return(verifier)
  end

  def stage1(id = upload.id, auth: 'Bearer good-token', params: body)
    headers = auth ? { 'Authorization' => auth } : {}
    post "/api/release_uploads/#{id}/stage1", params: params.to_json,
                                              headers: headers.merge('Content-Type' => 'application/json')
  end

  context 'with a token the verifier accepts' do
    before { allow(verifier).to receive(:call).with('good-token').and_return({}) }

    it 'records the report, answers 200 and creates no release' do
      expect { stage1 }.not_to change(Release, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('upload_id' => upload.id, 'stage' => 1, 'release_id' => nil)
      expect(upload.reload.metadata['package_name']).to eq('com.example.app')
    end

    it 'is idempotent' do
      stage1
      stage1
      expect(response).to have_http_status(:ok)
    end

    it 'answers 404 for an unknown upload and 409 for one that is not open' do
      stage1(0)
      expect(response).to have_http_status(:not_found)

      upload.update_columns(state: 'awaiting_bytes')
      stage1
      expect(response).to have_http_status(:conflict)
    end

    it 'answers 422 for a malformed report and changes nothing' do
      stage1(params: body.merge(package_name: 'nope'))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(upload.reload.stage1_at).to be_nil
    end
  end

  context 'without a valid token' do
    it 'refuses a missing header, with one generic answer, and changes nothing' do
      stage1(auth: nil)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Unauthorized')
      expect(upload.reload.stage1_at).to be_nil
    end

    it 'refuses a token the verifier rejects' do
      allow(verifier).to receive(:call).and_raise(GithubOidcVerifier::Invalid, 'bad signature')
      stage1

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Unauthorized')
      expect(upload.reload.stage1_at).to be_nil
    end

    it 'does not reveal whether an upload exists before authenticating' do
      allow(verifier).to receive(:call).and_raise(GithubOidcVerifier::Invalid, 'bad signature')
      stage1(0)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses everything while no audience is configured' do
      stub_const('ENV', ENV.to_h.except('CI_OIDC_AUDIENCE', 'ZEALOT_DOMAIN'))
      stage1

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not accept the old shared compile token or a per-app token' do
      allow(verifier).to receive(:call).and_raise(GithubOidcVerifier::Invalid, 'bad signature')
      stage1(auth: 'Bearer zpa_something')
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
