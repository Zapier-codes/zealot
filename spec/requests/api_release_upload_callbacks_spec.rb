# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a: the stage-1 callback door. Authentication is the GitHub OIDC token; the verifier is stubbed here
# (its own spec signs real tokens). Task 40i-b: a good report answers with the new release's id and storage tag.
# Needs Postgres. NOT run.
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

    it 'records the report and answers 200 with the new held release and its storage tag' do
      expect { stage1 }.to change(Release, :count).by(1)

      release = Release.order(:id).last
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('upload_id' => upload.id, 'stage' => 1, 'state' => 'processing',
                                              'release_id' => release.id,
                                              'storage_tag' => "a#{app.id}-r#{release.id}")
      expect(release.status).to eq('held')
      expect(upload.reload.metadata['package_name']).to eq('com.example.app')
    end

    it 'is idempotent and never creates a second release' do
      stage1
      expect { stage1 }.not_to change(Release, :count)
      expect(response).to have_http_status(:ok)
    end

    it 'answers 422 and creates no release when the release checks refuse the package' do
      channel.update!(bundle_id: 'com.other.app')

      expect { stage1 }.not_to change(Release, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('state' => 'failed')
      expect(upload.reload.state).to eq('failed')
    end

    it 'answers 404 for an unknown upload and 409 for one that is not open' do
      stage1(0)
      expect(response).to have_http_status(:not_found)

      upload.update_columns(state: 'awaiting_bytes')
      expect { stage1 }.not_to change(Release, :count)
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

  # Task 40i-c: the second report of the same workflow run. Same door, same OIDC token, same workflow file.
  describe 'stage 2' do
    let(:staging) { instance_double(ReleaseUploadStaging, delete: true, delete_sibling: true) }
    let(:storage) { instance_double(ReleaseStorage, exist?: true) }
    let(:release) do
      upload.update_columns(metadata: { 'kind' => 'apk', 'package_name' => 'com.example.app', 'version_code' => 3,
                                        'version_name' => '1.0', 'file_sha256' => 'a' * 64, 'file_size' => 2048 },
                            stage1_at: Time.current)
      ReleaseUploadReleaseBuilder.new(upload.reload, staging: staging).call.release
    end
    let(:keys) { ReleaseStorage.new(release, adapter: nil).staged_keys(filename: 'app.apk') }
    let(:report) { { state: 'ok', file_key: keys[:file], file_sha256: 'a' * 64 } }

    def stage2(id = upload.id, auth: 'Bearer good-token', params: report)
      headers = auth ? { 'Authorization' => auth } : {}
      post "/api/release_uploads/#{id}/stage2", params: params.to_json,
                                                headers: headers.merge('Content-Type' => 'application/json')
    end

    before do
      allow(verifier).to receive(:call).with('good-token').and_return({})
      allow(ReleaseUploadStaging).to receive(:new).and_return(staging)
      allow(ReleaseStorage).to receive(:new).and_wrap_original do |original, rel, **options|
        options.key?(:adapter) ? original.call(rel, **options) : storage
      end
      release
    end

    it 'finishes the release the first report made, creating none, and answers 200' do
      expect { stage2 }.not_to change(Release, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('upload_id' => upload.id, 'state' => 'done', 'stage' => 2,
                                              'release_id' => release.id, 'status' => 'available')
      expect(release.reload).to have_attributes(status: 'available', file_storage_key: keys[:file])
      expect(upload.reload.state).to eq('done')
    end

    it 'is idempotent' do
      stage2
      expect { stage2 }.not_to change { release.reload.updated_at }
      expect(response).to have_http_status(:ok)
    end

    it 'answers 422 and fails the upload when the file is not in storage' do
      allow(storage).to receive(:exist?).and_return(false)
      stage2

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('state' => 'failed')
      expect(release.reload).to have_attributes(status: 'held', file_storage_key: nil)
    end

    it 'records a failure report from CI' do
      stage2(params: { state: 'failed', error: 'bundletool failed' })

      expect(response).to have_http_status(:ok)
      expect(upload.reload).to have_attributes(state: 'failed', error: 'bundletool failed')
    end

    it 'answers 409 for an upload whose first report has not been made, and 404 for an unknown one' do
      other = ReleaseUpload.create!(channel: channel, filename: 'other.apk', declared_size: 10)
      other.update_columns(state: 'uploaded', uploaded_size: 10)
      expect { stage2(other.id) }.not_to change(Release, :count)
      expect(response).to have_http_status(:conflict)

      stage2(0)
      expect(response).to have_http_status(:not_found)
    end

    it 'refuses a missing header and a token the verifier rejects, before it looks the upload up' do
      stage2(auth: nil)
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq('error' => 'Unauthorized')

      allow(verifier).to receive(:call).and_raise(GithubOidcVerifier::Invalid, 'bad signature')
      stage2(0)
      expect(response).to have_http_status(:unauthorized)
      expect(upload.reload.state).to eq('processing')
    end
  end
end
