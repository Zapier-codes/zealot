# frozen_string_literal: true

# Task 40n-f (+40n-d3): Finds a harvested tenant APK in the storage repo and returns a short-lived
# download URL. The storage repo's release is tagged `tenant-<build_id>` and the asset is named
# `tenant-<build_id>.apk`.
#
# Works the same whether the storage repo is PUBLIC or PRIVATE. `browser_download_url` only works
# for a public repo and is permanent, so it is not used. Instead the asset API is asked for the
# file (`Accept: application/octet-stream`); GitHub answers 302 with a signed, short-lived
# `Location`, which is returned. The token is sent when GITHUB_STORAGE_TOKEN is set (required for a
# private repo, optional for a public one).
class TenantBuildDownload
  # `adapter` is only for specs: an array such as [:test, stubs] handed to Faraday's `adapter`, so the
  # request code (headers, token handling) runs for real without a network or the webmock gem.
  def initialize(build_id, adapter: nil)
    @build_id = build_id.to_s
    @adapter = adapter
  end

  def call
    return nil if @build_id.blank?

    tag = "tenant-#{@build_id}"
    asset_name = "tenant-#{@build_id}.apk"

    response = connection.get("repos/#{storage_repo}/releases/tags/#{tag}")
    return nil unless response.status == 200

    release_data = JSON.parse(response.body)
    asset = Array(release_data['assets']).find { |a| a['name'] == asset_name }
    return nil unless asset && asset['id']

    signed_url(asset['id'])
  rescue Faraday::Error, JSON::ParserError
    nil
  end

  private

  def signed_url(asset_id)
    response = connection.get("repos/#{storage_repo}/releases/assets/#{asset_id}") do |req|
      req.headers['Accept'] = 'application/octet-stream'
    end
    return nil unless [301, 302, 303, 307, 308].include?(response.status)

    response.headers['location'].presence
  end

  def connection
    headers = {
      'Accept' => 'application/vnd.github+json',
      'User-Agent' => 'Zealot'
    }
    token = ENV['GITHUB_STORAGE_TOKEN'].to_s
    headers['Authorization'] = "Bearer #{token}" if token.present?

    Faraday.new(url: 'https://api.github.com', headers: headers, request: { open_timeout: 5, timeout: 15 }) do |f|
      f.adapter(*@adapter) if @adapter
    end
  end

  def storage_repo
    ENV['GITHUB_STORAGE_REPO'].to_s
  end
end
