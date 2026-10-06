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
    let(:secret) { 'test-link-secret' }
    let(:expires) { Time.now.to_i + 600 }
    let(:signature) { TenantBuildLink.sign(build_id, expires, secret: secret) }
    let(:door) { "/api/tenant_builds/#{build_id}/download?expires=#{expires}&signature=#{signature}" }

    # Subclasses of the example fill `stubs` through `github`.
    let(:stubs) { Faraday::Adapter::Test::Stubs.new }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_REPO').and_return(storage_repo)
      allow(ENV).to receive(:[]).with('GITHUB_STORAGE_TOKEN').and_return(token)
      allow(ENV).to receive(:[]).with('DISTR_LINK_SECRET').and_return(secret)
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

    describe 'door auth' do
      before do
        github(tag_path, status: 200, body: release_body)
        github(asset_path, status: 302, headers: { 'Location' => signed_url })
      end

      def expect_refused(status)
        expect(response).to have_http_status(status)
        expect(response).not_to be_redirect
        expect(seen).to be_empty # GitHub was never contacted
      end

      it 'refuses a link with no signature' do
        get "/api/tenant_builds/#{build_id}/download"
        expect_refused(:unauthorized)
      end

      it 'refuses a link with a wrong signature' do
        get "/api/tenant_builds/#{build_id}/download?expires=#{expires}&signature=#{'0' * 64}"
        expect_refused(:unauthorized)
      end

      it 'refuses a malformed signature or expiry' do
        get "/api/tenant_builds/#{build_id}/download?expires=abc&signature=xyz"
        expect_refused(:unauthorized)
      end

      it 'refuses a signature made for another build' do
        other = TenantBuildLink.sign('b999', expires, secret: secret)
        get "/api/tenant_builds/#{build_id}/download?expires=#{expires}&signature=#{other}"
        expect_refused(:unauthorized)
      end

      it 'refuses a link whose expiry was changed after signing' do
        get "/api/tenant_builds/#{build_id}/download?expires=#{expires + 60}&signature=#{signature}"
        expect_refused(:unauthorized)
      end

      it 'refuses a signature made with another secret' do
        forged = TenantBuildLink.sign(build_id, expires, secret: 'not-the-secret')
        get "/api/tenant_builds/#{build_id}/download?expires=#{expires}&signature=#{forged}"
        expect_refused(:unauthorized)
      end

      it 'refuses an expired link and says how to get a new one' do
        past = Time.now.to_i - 5
        get "/api/tenant_builds/#{build_id}/download?expires=#{past}&signature=#{TenantBuildLink.sign(build_id, past, secret: secret)}"
        expect_refused(:unauthorized)
        expect(response.body).to include('expired')
      end

      it 'refuses a genuine signature with an expiry beyond the longest allowed life' do
        far = Time.now.to_i + TenantBuildLink::MAX_TTL + 3600
        get "/api/tenant_builds/#{build_id}/download?expires=#{far}&signature=#{TenantBuildLink.sign(build_id, far, secret: secret)}"
        expect_refused(:unauthorized)
      end

      it 'stays closed (503) when DISTR_LINK_SECRET is not set' do
        allow(ENV).to receive(:[]).with('DISTR_LINK_SECRET').and_return(nil)
        get door
        expect_refused(:service_unavailable)
      end

      it 'accepts a correctly signed, unexpired link' do
        get door
        expect(response).to redirect_to(signed_url)
      end
    end

    context 'when the build exists in storage (private repo, token set)' do
      before do
        github(tag_path, status: 200, body: release_body)
        github(asset_path, status: 302, headers: { 'Location' => signed_url })
      end

      it 'redirects to the short-lived signed URL, sending the token' do
        get door
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
        get door
        expect(response).to redirect_to(signed_url)
        expect(seen).not_to be_empty
        expect(seen.none? { |h| h.key?('Authorization') }).to be(true)
      end
    end

    context 'when the release exists but the asset is missing' do
      before { github(tag_path, status: 200, body: { 'assets' => [] }.to_json) }

      it 'returns 404' do
        get door
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the build does not exist' do
      before { github(tag_path, status: 404) }

      it 'returns 404 with an expired message' do
        get door
        expect(response).to have_http_status(:not_found)
        expect(response.body).to include('expired')
      end
    end
  end
end
