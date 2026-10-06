import os

os.chdir(os.path.expanduser('~/zealot'))

# 1. Create Service
service_content = """# frozen_string_literal: true

# Task 40n-f: Finds a harvested tenant APK in the storage repo and returns its short-lived
# GitHub download URL. The storage repo's release is tagged `tenant-<build_id>` and the
# asset is named `tenant-<build_id>.apk`.
class TenantBuildDownload
  def initialize(build_id)
    @build_id = build_id.to_s
  end

  def call
    return nil if @build_id.blank?

    tag = "tenant-#{@build_id}"
    asset_name = "tenant-#{@build_id}.apk"

    response = connection.get("repos/#{storage_repo}/releases/tags/#{tag}")
    return nil unless response.status == 200

    release_data = JSON.parse(response.body)
    asset = release_data['assets'].find { |a| a['name'] == asset_name }
    return nil unless asset

    asset['browser_download_url']
  rescue Faraday::Error, JSON::ParserError
    nil
  end

  private

  def connection
    Faraday.new(
      url: 'https://api.github.com',
      headers: {
        'Authorization' => "Bearer #{ENV['GITHUB_STORAGE_TOKEN'].to_s}",
        'Accept' => 'application/vnd.github+json',
        'User-Agent' => 'Zealot'
      },
      request: { open_timeout: 5, timeout: 15 }
    )
  end

  def storage_repo
    ENV['GITHUB_STORAGE_REPO'].to_s
  end
end
"""
os.makedirs('app/services', exist_ok=True)
with open('app/services/tenant_build_download.rb', 'w') as f:
    f.write(service_content)

# 2. Create Controller
controller_content = """# frozen_string_literal: true

# Task 40n-f: The door distr's download button hits. It takes a build_id,
# finds the signed APK in the storage repo, and redirects the user to a
# short-lived GitHub download URL. No GitHub account is required by the user.
class Api::TenantBuildsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def download
    build_id = params[:build_id]
    url = TenantBuildDownload.new(build_id).call

    if url
      redirect_to url, allow_other_host: true
    else
      render plain: 'This build has expired, does not exist, or has been deleted. Please request a rebuild from distr.', status: :not_found
    end
  end
end
"""
os.makedirs('app/controllers/api', exist_ok=True)
with open('app/controllers/api/tenant_builds_controller.rb', 'w') as f:
    f.write(controller_content)

# 3. Update routes.rb
with open('config/routes.rb', 'r') as f:
    s = f.read()

s = s.replace(
    "    post 'ci_compile/:id/callback', to: 'ci_compile#callback'",
    "    post 'ci_compile/:id/callback', to: 'ci_compile#callback'\n    get 'tenant_builds/:build_id/download', to: 'tenant_builds#download', as: :tenant_build_download"
)
with open('config/routes.rb', 'w') as f:
    f.write(s)

# 4. Create Spec
spec_content = """# frozen_string_literal: true

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
"""
os.makedirs('spec/requests', exist_ok=True)
with open('spec/requests/api_tenant_builds_download_spec.rb', 'w') as f:
    f.write(spec_content)

# 5. Update handover.md
with open('handover.md', 'r') as f:
    s = f.read()

s = s.replace("| 40n-f | **Delivery: the file behind the email button.**", "| 40n-f ✅ | **Delivery: the file behind the email button.**")

result_block = """
#### 40n-f result (built this session; written, NOT run)

**What it is.** A public endpoint `GET /api/tenant_builds/:build_id/download` that distr's email button points to. It queries the storage repo for the `tenant-<build_id>` release, finds the signed APK asset, and redirects the user to the short-lived GitHub download URL. If the release or asset is missing (e.g., expired), it returns a 404 with a message telling the user to request a rebuild.

**Files (3).** `app/services/tenant_build_download.rb` (new), `app/controllers/api/tenant_builds_controller.rb` (new), `config/routes.rb` (updated), `spec/requests/api_tenant_builds_download_spec.rb` (new).

**Not verified.** Nothing was run.
"""
s = s.replace("| 40n-g | **distr side (not in this repo).**", result_block + "\n| 40n-g | **distr side (not in this repo).**")

with open('handover.md', 'w') as f:
    f.write(s)

print("40n-f created successfully.")
