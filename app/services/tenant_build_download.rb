# frozen_string_literal: true

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
