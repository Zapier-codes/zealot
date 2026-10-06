# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::TenantBuildsController, type: :request do
  describe 'GET /api/tenant_builds/:build_id/download' do
    let(:build_id) { 'b123' }
    let(:storage_repo) { 'Zapier-codes/zealot-storage' }
    let(:token) { 'ghp_xxx' }
    let(:asset_url) { 'https://github.com/Zapier-codes/zealot-storage/releases/download/tenant-b123/tenant-b123.apk' }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_REPO').and_return(storage_repo)
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(token)
    end

    context 'when the build exists in storage' do
      before do
        stub_request(:get, "https://api.github.com/repos/#{storage_repo}/releases/tags/tenant-#{build_id}")
          .to_return(status: 200, body: {
            'assets' => [
              { 'name' => "tenant-#{build_id}.apk", 'browser_download_url' => asset_url }
            ]
          }.to_json)
      end

      it 'redirects to the GitHub download URL' do
        get "/api/tenant_builds/#{build_id}/download"
        expect(response).to redirect_to(asset_url)
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
