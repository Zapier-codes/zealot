# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::TenantBuildsController, type: :request do
  describe 'GET /api/tenant_builds/:build_id/download' do
    let(:build_id) { 'b123' }
    let(:storage_repo) { 'Zapier-codes/zealot-storage' }
    let(:token) { 'ghp_xxx' }
    let(:asset_id) { 777 }
    let(:signed_url) { 'https://release-assets.githubusercontent.com/signed/tenant-b123.apk?sig=abc' }
    let(:tag_url) { "https://api.github.com/repos/#{storage_repo}/releases/tags/tenant-#{build_id}" }
    let(:asset_api_url) { "https://api.github.com/repos/#{storage_repo}/releases/assets/#{asset_id}" }
    let(:release_body) { { 'assets' => [{ 'id' => asset_id, 'name' => "tenant-#{build_id}.apk" }] }.to_json }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_REPO').and_return(storage_repo)
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(token)
    end

    context 'when the build exists in storage (private repo, token set)' do
      before do
        stub_request(:get, tag_url).with(headers: { 'Authorization' => "Bearer #{token}" })
          .to_return(status: 200, body: release_body)
        stub_request(:get, asset_api_url)
          .with(headers: { 'Authorization' => "Bearer #{token}", 'Accept' => 'application/octet-stream' })
          .to_return(status: 302, headers: { 'Location' => signed_url })
      end

      it 'redirects to the short-lived signed URL' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to redirect_to(signed_url)
      end
    end

    context 'when the build exists in storage (public repo, no token)' do
      before do
        allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(nil)
        stub_request(:get, tag_url).to_return(status: 200, body: release_body)
        stub_request(:get, asset_api_url)
          .with(headers: { 'Accept' => 'application/octet-stream' })
          .to_return(status: 302, headers: { 'Location' => signed_url })
      end

      it 'still redirects to the signed URL, sending no Authorization header' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to redirect_to(signed_url)
        expect(a_request(:get, tag_url).with { |r| !r.headers.key?('Authorization') }).to have_been_made
      end
    end

    context 'when the release exists but the asset is missing' do
      before do
        stub_request(:get, tag_url).to_return(status: 200, body: { 'assets' => [] }.to_json)
      end

      it 'returns 404' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the build does not exist' do
      before do
        stub_request(:get, "https://api.github.com/repos/#{storage_repo}/releases/tags/tenant-#{build_id}")
          .to_return(status: 404)
      end

      it 'returns 404 with an expired message' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include('expired')
      end
    end
  end
end
