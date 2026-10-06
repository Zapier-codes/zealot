# frozen_string_literal: true

require 'rails_helper'

# Task 42c: stubs GitHub with Faraday's own test adapter (TenantBuildDownload takes an `adapter:` for this), so
# the spec needs no webmock gem (webmock was never in Gemfile.lock, which failed every example here).
RSpec.describe Api::TenantBuildsController, type: :request do
  describe 'GET /api/tenant_builds/:build_id/download' do
    let(:build_id) { 'b123' }
    let(:storage_repo) { 'Zapier-codes/zealot-storage' }
    let(:token) { 'ghp_xxx' }
    let(:asset_id) { 777 }
    let(:signed_url) { 'https://release-assets.githubusercontent.com/signed/tenant-b123.apk?sig=abc' }
    let(:tag_path) { "/repos/#{storage_repo}/releases/tags/tenant-#{build_id}" }
    let(:asset_path) { "/repos/#{storage_repo}/releases/assets/#{asset_id}" }
    let(:release_body) { { 'assets' => [{ 'id' => asset_id, 'name' => "tenant-#{build_id}.apk" }] }.to_json }
    let(:seen) { [] } # request headers of every call GitHub received

    # Subclasses of the example fill `stubs` through `github`.
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_REPO').and_return(storage_repo)
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(token)
      test_stubs = stubs
      allow(TenantBuildDownload).to receive(:new).and_wrap_original do |original, id|
        original.call(id, adapter: [:test, test_stubs])
      end
    end

    def github(path, status:, body: '', headers: {})
      recorder = seen
      stubs.get(path) do |env|
        recorder << env.request_headers.to_h
        [status, headers, body]
      end
    end

    context 'when the build exists in storage (private repo, token set)' do
      before do
        github(tag_path, status: 200, body: release_body)
        github(asset_path, status: 302, headers: { 'Location' => signed_url })
      end

      it 'redirects to the short-lived signed URL, sending the token' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to redirect_to(signed_url)
        expect(seen.map { |h| h['Authorization'] }.uniq).to eq(["Bearer #{token}"])
        expect(seen.last['Accept']).to eq('application/octet-stream')
      end
    end

    context 'when the build exists in storage (public repo, no token)' do
      before do
        allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(nil)
        github(tag_path, status: 200, body: release_body)
        github(asset_path, status: 302, headers: { 'Location' => signed_url })
      end

      it 'still redirects to the signed URL, sending no Authorization header' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to redirect_to(signed_url)
        expect(seen).not_to be_empty
        expect(seen.none? { |h| h.key?('Authorization') }).to be(true)
      end
    end

    context 'when the release exists but the asset is missing' do
      before { github(tag_path, status: 200, body: { 'assets' => [] }.to_json) }

      it 'returns 404' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the build does not exist' do
      before { github(tag_path, status: 404) }

      it 'returns 404 with an expired message' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include('expired')
      end
    end
  end
end
