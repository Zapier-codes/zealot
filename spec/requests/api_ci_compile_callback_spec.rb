# frozen_string_literal: true

require 'rails_helper'

# Task 40a: `POST /api/ci_compile/:id/callback`, the storage repo's compile workflow reporting its
# result. Needs Postgres. Built by imitating release_status_control_spec.rb (release construction)
# and api_android_signing_key_spec.rb (Authorization header); NOT run (the operator said no testing),
# so look here first if CI is red for this slice. Storage is stubbed: no GitHub call is made.
RSpec.describe 'API CI compile callback', type: :request do
  let(:token) { 'ci-callback-secret-1' }
  let(:sha) { 'a' * 64 }
  let(:cert) { 'b' * 64 }
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:state) { 'dispatched' }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1',
                ci_compile_state: state)
           .tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/ci_compile/#{release.id}/callback" }
  let(:storage) { instance_double(ReleaseStorage, exist?: true) }

  def bearer(secret = token)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def done_body(**overrides)
    { state: 'done', universal_apk_key: 'uploads/apps/a1/r1/pipeline/universal.apk',
      universal_apk_sha256: sha, universal_apk_size: 1234,
      compressed_apks_key: 'uploads/apps/a1/r1/pipeline/release.apks.br', compressed_size: 99 }.merge(overrides)
  end

  def call(body, headers: bearer)
    post path, params: body.to_json, headers: headers.merge('Content-Type' => 'application/json')
  end

  before do
    Zealot::TenantRegistry.reset!
    stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_CALLBACK_TOKEN' => token))
    allow(ReleaseStorage).to receive(:new).and_return(storage)
  end

  describe 'authentication' do
    it 'refuses a call with no token' do
      call(done_body, headers: {})

      expect(response).to have_http_status(:unauthorized)
      expect(release.reload.ci_compile_state).to eq('dispatched')
    end

    it 'refuses a wrong token' do
      call(done_body, headers: bearer('nope'))

      expect(response).to have_http_status(:unauthorized)
      expect(release.reload.ci_compile_state).to eq('dispatched')
    end

    it 'refuses everything when the server has no token configured, even an empty one' do
      stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_CALLBACK_TOKEN' => ''))

      call(done_body, headers: bearer(''))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not accept the token as a query parameter' do
      post "#{path}?token=#{token}", params: done_body.to_json, headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not reveal whether a release exists to a caller without the token' do
      post '/api/ci_compile/0/callback', params: done_body.to_json,
                                         headers: { 'Content-Type' => 'application/json' }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'a done result' do
    it 'flips dispatched to done and records what CI built' do
      call(done_body)

      expect(response).to have_http_status(:ok)
      release.reload
      expect(release.ci_compile_state).to eq('done')
      expect(release.ci_compile_error).to be_nil
      expect(release.ci_compile_finished_at).to be_present
      expect(release.universal_apk_storage_key).to eq('uploads/apps/a1/r1/pipeline/universal.apk')
      expect(release.universal_apk_sha256).to eq(sha)
      expect(release.universal_apk_size).to eq(1234)
      expect(release.compressed_apks_storage_key).to eq('uploads/apps/a1/r1/pipeline/release.apks.br')
      expect(release.compressed_size).to eq(99)
      expect(release.brotli_compressed).to be(true)
    end

    context 'when the release is still queued' do
      let(:state) { 'queued' }

      it 'accepts the result (the workflow can finish before the dispatch is recorded)' do
        call(done_body)

        expect(response).to have_http_status(:ok)
        expect(release.reload.ci_compile_state).to eq('done')
      end
    end

    it 'answers a repeat of the same call with 200 and writes nothing' do
      call(done_body)
      finished_at = release.reload.ci_compile_finished_at

      call(done_body)

      expect(response).to have_http_status(:ok)
      expect(release.reload.ci_compile_finished_at).to eq(finished_at)
    end

    it 'refuses a different result for a release that is already done' do
      call(done_body)

      call(done_body(universal_apk_sha256: 'c' * 64))

      expect(response).to have_http_status(:conflict)
      expect(release.reload.universal_apk_sha256).to eq(sha)
    end

    it 'refuses a release that was never sent to CI' do
      release.update_columns(ci_compile_state: nil)

      call(done_body)

      expect(response).to have_http_status(:conflict)
      expect(release.reload.ci_compile_state).to be_nil
    end

    it 'refuses a malformed body with 422 and changes nothing, so CI can send it again' do
      [done_body(universal_apk_sha256: 'xyz'), done_body(universal_apk_size: 0),
       done_body(universal_apk_key: ''), done_body(compressed_apks_key: nil),
       done_body(compressed_size: 'big')].each do |body|
        call(body)

        expect(response).to have_http_status(:unprocessable_entity)
      end
      expect(release.reload.ci_compile_state).to eq('dispatched')
    end

    it 'marks the release failed, with the reason, when a file CI named is not in storage' do
      allow(storage).to receive(:exist?).with('uploads/apps/a1/r1/pipeline/release.apks.br').and_return(false)

      call(done_body)

      expect(response).to have_http_status(:unprocessable_entity)
      release.reload
      expect(release.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to include('release.apks.br')
      expect(release.universal_apk_sha256).to be_nil
    end

    context 'when an expected signing certificate is configured' do
      before do
        stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_CALLBACK_TOKEN' => token,
                                            'CI_COMPILE_EXPECT_CERT_SHA256' => cert.upcase.scan(/../).join(':')))
      end

      it 'accepts a matching certificate, in keytool form or bare hex' do
        call(done_body(cert_sha256: cert))

        expect(response).to have_http_status(:ok)
        expect(release.reload.ci_compile_state).to eq('done')
      end

      it 'marks the release failed when the certificate differs' do
        call(done_body(cert_sha256: 'd' * 64))

        expect(response).to have_http_status(:unprocessable_entity)
        expect(release.reload.ci_compile_state).to eq('failed')
        expect(release.ci_compile_error).to include('certificate')
      end

      it 'refuses a body that reports no certificate, without changing the state' do
        call(done_body)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(release.reload.ci_compile_state).to eq('dispatched')
      end
    end
  end

  describe 'a failed result' do
    it 'flips dispatched to failed and keeps the reason' do
      call(state: 'failed', error: 'bundletool exited 1')

      expect(response).to have_http_status(:ok)
      release.reload
      expect(release.ci_compile_state).to eq('failed')
      expect(release.ci_compile_error).to eq('bundletool exited 1')
      expect(release.ci_compile_finished_at).to be_present
    end

    it 'refuses a failure for a release that is already done' do
      release.update_columns(ci_compile_state: 'done')

      call(state: 'failed', error: 'late')

      expect(response).to have_http_status(:conflict)
      expect(release.reload.ci_compile_state).to eq('done')
    end
  end

  it 'refuses an unknown state' do
    call(state: 'pending')

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'answers 404 for an unknown release to a caller who has the token' do
    post '/api/ci_compile/0/callback', params: done_body.to_json,
                                       headers: bearer.merge('Content-Type' => 'application/json')

    expect(response).to have_http_status(:not_found)
  end
end
