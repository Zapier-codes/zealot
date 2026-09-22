# frozen_string_literal: true

require 'net/http'
require 'openssl'
require 'json'
require 'uri'
require 'fileutils'

# Stores release artifacts as GitHub Release assets in a dedicated *storage*
# repository (Task 19). Selected when RELEASE_STORAGE_ADAPTER=github.
#
# Required env vars:
#   GITHUB_STORAGE_REPO   - "owner/name" of the storage repo. Must NOT be this
#                           code repo: its tag-triggered workflows would fire
#                           for every stored build (see handover.md Task 19).
#   GITHUB_STORAGE_TOKEN  - fine-grained token scoped to that one repo with
#                           "Contents: read and write". Never logged.
# Optional:
#   GITHUB_API_URL              - defaults to https://api.github.com
#   GITHUB_STORAGE_ALLOW_PUBLIC - "true" to allow a *public* storage repo.
#                                 Off by default: release assets in a public
#                                 repo are downloadable by anyone.
#
# Layout: one GitHub release per Zealot release, tagged "a<app>-r<release>",
# holding that release's files as assets. A storage key such as
#   uploads/apps/a12/r345/pipeline/release.apks.br
# becomes tag "a12-r345" + asset "pipeline__release.apks.br" (asset names
# cannot contain "/"). The uploaded file itself, key .../binary/app.apk, drops
# the "binary/" prefix and becomes asset "app.apk", because the download's file
# name is the asset name and users should get "app.apk", not "binary__app.apk".
# Keys that don't follow the uploads/apps/a<id>/r<id>/...
# convention are rejected rather than piled into one shared release, because a
# release holds at most 1000 assets.
#
# Limits and behaviour worth knowing:
# - Each asset must be under 2 GiB (GitHub's limit); larger files raise
#   StorageError before any upload starts.
# - `content_encoding` is accepted for interface parity but GitHub cannot
#   store it; the bytes are stored as given and `fetch` returns them as-is.
# - Downloads never send the token to the download host: the authenticated
#   API call returns a short-lived signed URL and only that is fetched (or,
#   for `url_for`, handed to the caller, who must redirect to it promptly).
#
# Not verified against the live GitHub API from the sandbox this was written
# in; the specs run against an in-memory fake of the endpoints used.
class ReleaseStorage::GithubAdapter
  DEFAULT_API_URL = 'https://api.github.com'
  API_VERSION = '2022-11-28'
  MAX_ASSET_BYTES = (2 * 1024**3) - 1
  MAX_ATTEMPTS = 3
  RETRY_STATUSES = [429, 500, 502, 503, 504].freeze
  KEY_PATTERN = %r{\A(?:uploads/)?apps/(a\d+)/(r\d+)/(.+)\z}
  REPO_PATTERN = %r{\A[\w.-]+/[\w.-]+\z}
  VERIFY_TTL = 600

  Response = Struct.new(:status, :headers, :body, keyword_init: true) do
    def success?
      status.between?(200, 299)
    end
  end

  # Default network layer. Kept separate so specs can swap in an in-memory
  # fake and so streaming (uploads and downloads) never buffers a whole file.
  class HttpTransport
    NETWORK_ERRORS = [
      Timeout::Error, SocketError, EOFError, IOError, Errno::ECONNRESET, Errno::ECONNREFUSED,
      Errno::EPIPE, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError
    ].freeze

    def call(method, url, headers: {}, body: nil, upload_path: nil, stream_to: nil)
      uri = URI.parse(url)
      request = Net::HTTPGenericRequest.new(method.to_s.upcase, !body.nil? || !upload_path.nil?, true, uri.request_uri)
      headers.each { |name, value| request[name] = value }
      request.body = body if body

      upload = upload_path && File.open(upload_path, 'rb')
      if upload
        request.body_stream = upload
        request['Content-Length'] = File.size(upload_path).to_s
      end

      perform(uri, request, stream_to)
    ensure
      upload&.close
    end

    private

    def perform(uri, request, stream_to)
      result = nil
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 15, read_timeout: 300) do |http|
        http.request(request) do |response|
          if stream_to && response.is_a?(Net::HTTPSuccess)
            FileUtils.mkdir_p(File.dirname(stream_to))
            File.open(stream_to, 'wb') { |file| response.read_body { |chunk| file.write(chunk) } }
            result = build_response(response, nil)
          else
            result = build_response(response, response.body)
          end
        end
      end
      result
    end

    def build_response(response, body)
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      Response.new(status: response.code.to_i, headers: headers, body: body)
    end
  end

  class << self
    # Remembers which storage repos passed the visibility/access check so it
    # costs one API call per process per VERIFY_TTL, not one per operation.
    def verified?(repo)
      verified_at = verification_mutex.synchronize { verified_repos[repo] }
      !verified_at.nil? && (Time.now - verified_at) < VERIFY_TTL
    end

    def mark_verified(repo)
      verification_mutex.synchronize { verified_repos[repo] = Time.now }
    end

    def reset_verification!
      verification_mutex.synchronize { verified_repos.clear }
    end

    private

    def verified_repos
      @verified_repos ||= {}
    end

    def verification_mutex
      @verification_mutex ||= Mutex.new
    end
  end

  def initialize(repo: ENV['GITHUB_STORAGE_REPO'], token: ENV['GITHUB_STORAGE_TOKEN'], api_url: ENV['GITHUB_API_URL'],
                 transport: HttpTransport.new, sleeper: ->(seconds) { sleep(seconds) })
    @repo = repo.to_s.strip
    @token = token.to_s.strip
    @api_url = (api_url.to_s.strip.empty? ? DEFAULT_API_URL : api_url.to_s.strip).chomp('/')
    @transport = transport
    @sleeper = sleeper
    ensure_configured!
  end

  def put(key, local_path, content_encoding: nil, content_type: nil) # rubocop:disable Lint/UnusedMethodArgument
    ensure_repo_usable!
    tag, name = locate(key)

    size = File.size(local_path)
    if size > MAX_ASSET_BYTES
      raise ReleaseStorage::StorageError,
            "GitHub put failed for #{key}: file is #{size} bytes, GitHub release assets must be under 2 GiB"
    end

    release = find_or_create_release(tag)
    existing = list_assets(release['id']).find { |asset| asset['name'] == name }
    delete_asset(existing['id']) if existing
    upload_asset(release, name, local_path, size, content_type || 'application/octet-stream')
    key
  end

  def get(key, to)
    ensure_repo_usable!
    _release, asset = locate_asset(key)
    return nil unless asset

    signed_url = signed_download_url(asset['id'])
    raise ReleaseStorage::StorageError, "GitHub get failed for #{key}: no download URL returned" unless signed_url

    partial = "#{to}.part"
    FileUtils.mkdir_p(File.dirname(to))
    response = request(:get, signed_url, authorize: false, stream_to: partial)
    unless response.success?
      FileUtils.rm_f(partial)
      fail_for(response, "get #{key}")
    end
    File.rename(partial, to)
    to
  end

  # Short-lived signed URL straight from GitHub's CDN, or nil if the key
  # doesn't exist. GitHub decides the expiry (a few minutes), so `expires_in`
  # is ignored and callers must redirect to the URL right away, not store it.
  def url_for(key, expires_in: nil) # rubocop:disable Lint/UnusedMethodArgument
    ensure_repo_usable!
    _release, asset = locate_asset(key)
    asset && signed_download_url(asset['id'])
  end

  def delete(key)
    ensure_repo_usable!
    release, asset = locate_asset(key)
    return true unless asset

    delete_asset(asset['id'])
    remove_release_if_empty(release)
    true
  end

  def exist?(key)
    ensure_repo_usable!
    _release, asset = locate_asset(key)
    !asset.nil?
  end

  private

  # --- key mapping ---------------------------------------------------------

  def locate(key)
    match = KEY_PATTERN.match(key.to_s)
    unless match
      raise ReleaseStorage::StorageError,
            "GitHub storage cannot store key #{key.inspect}: expected uploads/apps/a<id>/r<id>/<file>"
    end

    ["#{match[1]}-#{match[2]}", sanitize_asset_name(match[3].delete_prefix('binary/').gsub('/', '__'))]
  end

  # GitHub rewrites unusual characters in asset names on upload, which would
  # make our own lookups miss; normalise up front so name == stored name.
  def sanitize_asset_name(name)
    name.gsub(/[^A-Za-z0-9._-]/, '_')
  end

  # --- setup and safety checks --------------------------------------------

  def ensure_configured!
    missing = []
    missing << 'GITHUB_STORAGE_REPO' if @repo.empty?
    missing << 'GITHUB_STORAGE_TOKEN' if @token.empty?
    unless missing.empty?
      raise ReleaseStorage::ConfigurationError,
            "GitHub adapter selected but missing env vars: #{missing.join(', ')}"
    end
    return if REPO_PATTERN.match?(@repo)

    raise ReleaseStorage::ConfigurationError, "GITHUB_STORAGE_REPO must look like owner/name, got #{@repo.inspect}"
  end

  # Runs once per process per VERIFY_TTL: confirms the token can reach the
  # repo with write access, and refuses a public repo unless explicitly allowed.
  def ensure_repo_usable!
    return if self.class.verified?(@repo)

    response = request(:get, "#{@api_url}/repos/#{@repo}")
    case response.status
    when 200
      data = parse(response)
      check_write_access!(data)
      check_visibility!(data)
      self.class.mark_verified(@repo)
    when 401, 403, 404
      raise ReleaseStorage::ConfigurationError,
            "GitHub storage repo #{@repo} not found or the token has no access to it (HTTP #{response.status})"
    else
      fail_for(response, "repo check #{@repo}")
    end
  end

  def check_write_access!(data)
    permissions = data['permissions']
    return unless permissions.is_a?(Hash) && permissions['push'] == false

    raise ReleaseStorage::ConfigurationError,
          "GITHUB_STORAGE_TOKEN can read #{@repo} but cannot write to it (needs Contents: read and write)"
  end

  def check_visibility!(data)
    return if data['private'] == true

    unless ENV['GITHUB_STORAGE_ALLOW_PUBLIC'] == 'true'
      raise ReleaseStorage::ConfigurationError,
            "GitHub storage repo #{@repo} is public: anyone could download every stored build. Make it " \
            'private, or set GITHUB_STORAGE_ALLOW_PUBLIC=true to accept that knowingly.'
    end

    return unless defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger

    Rails.logger.warn("[ReleaseStorage::GithubAdapter] #{@repo} is PUBLIC; stored builds are downloadable by anyone")
  end

  # --- GitHub API helpers --------------------------------------------------

  def locate_asset(key)
    tag, name = locate(key)
    release = find_release(tag)
    return [nil, nil] unless release

    [release, list_assets(release['id']).find { |asset| asset['name'] == name }]
  end

  def find_release(tag)
    response = request(:get, "#{repo_url}/releases/tags/#{URI.encode_www_form_component(tag)}")
    return parse(response) if response.status == 200
    return nil if response.status == 404

    fail_for(response, "find release #{tag}")
  end

  def find_or_create_release(tag)
    find_release(tag) || create_release(tag)
  end

  def create_release(tag)
    payload = { tag_name: tag, name: tag, body: 'Zealot release storage. Managed automatically; do not edit.',
                prerelease: true }
    response = request(:post, "#{repo_url}/releases", headers: { 'Content-Type' => 'application/json' },
                                                       body: JSON.generate(payload))
    return parse(response) if response.status == 201

    # Lost a race with another writer creating the same tag; use theirs.
    if response.status == 422
      existing = find_release(tag)
      return existing if existing
    end
    fail_for(response, "create release #{tag}")
  end

  def list_assets(release_id)
    assets = []
    (1..10).each do |page|
      response = request(:get, "#{repo_url}/releases/#{release_id}/assets?per_page=100&page=#{page}")
      fail_for(response, "list assets of release #{release_id}") unless response.status == 200

      batch = parse(response)
      assets.concat(batch)
      break if batch.size < 100
    end
    assets
  end

  def upload_asset(release, name, local_path, size, content_type)
    base = release['upload_url'].to_s.sub(/\{[^}]*\}\z/, '')
    url = "#{base}?name=#{URI.encode_www_form_component(name)}"
    response = request(:post, url, headers: { 'Content-Type' => content_type, 'Content-Length' => size.to_s },
                                   upload_path: local_path)
    fail_for(response, "upload #{name}") unless response.status == 201
  end

  def delete_asset(asset_id)
    response = request(:delete, "#{repo_url}/releases/assets/#{asset_id}")
    fail_for(response, "delete asset #{asset_id}") unless [204, 404].include?(response.status)
  end

  # A release with no assets left is dead weight; remove it and its tag so
  # the storage repo doesn't accumulate empty releases.
  def remove_release_if_empty(release)
    return unless list_assets(release['id']).empty?

    response = request(:delete, "#{repo_url}/releases/#{release['id']}")
    fail_for(response, "delete release #{release['tag_name']}") unless [204, 404].include?(response.status)

    ref = request(:delete, "#{repo_url}/git/refs/tags/#{URI.encode_www_form_component(release['tag_name'])}")
    fail_for(ref, "delete tag #{release['tag_name']}") unless [204, 404, 422].include?(ref.status)
  end

  # Authenticated call that asks for the raw asset; GitHub answers with a
  # redirect to a short-lived signed URL. Only that URL is ever downloaded.
  def signed_download_url(asset_id)
    response = request(:get, "#{repo_url}/releases/assets/#{asset_id}",
                       headers: { 'Accept' => 'application/octet-stream' })
    return response.headers['location'] if [301, 302, 303, 307, 308].include?(response.status)
    return nil if response.status == 404

    fail_for(response, "resolve download for asset #{asset_id}")
  end

  def repo_url
    "#{@api_url}/repos/#{@repo}"
  end

  # --- HTTP plumbing -------------------------------------------------------

  def request(method, url, headers: {}, body: nil, upload_path: nil, stream_to: nil, authorize: true)
    all_headers = { 'Accept' => 'application/vnd.github+json', 'User-Agent' => 'zealot-release-storage',
                    'X-GitHub-Api-Version' => API_VERSION }.merge(headers)
    all_headers['Authorization'] = "Bearer #{@token}" if authorize

    attempts = 0
    loop do
      attempts += 1
      begin
        response = @transport.call(method, url, headers: all_headers, body: body, upload_path: upload_path,
                                                stream_to: stream_to)
      rescue *HttpTransport::NETWORK_ERRORS => e
        if attempts >= MAX_ATTEMPTS
          raise ReleaseStorage::StorageError,
                "GitHub request failed (#{method.to_s.upcase} #{redact(url)}): #{e.class}"
        end

        @sleeper.call(backoff(attempts))
        next
      end

      if RETRY_STATUSES.include?(response.status) && attempts < MAX_ATTEMPTS
        @sleeper.call(backoff(attempts))
        next
      end
      return response
    end
  end

  def backoff(attempt)
    2**(attempt - 1)
  end

  def parse(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise ReleaseStorage::StorageError, "GitHub returned a non-JSON body (HTTP #{response.status})"
  end

  def fail_for(response, action)
    detail = begin
      JSON.parse(response.body.to_s)['message']
    rescue JSON::ParserError, TypeError
      nil
    end
    detail = "#{detail}; " if detail
    if response.status == 403 && response.headers['x-ratelimit-remaining'] == '0'
      detail = "#{detail}rate limit exhausted, resets at #{response.headers['x-ratelimit-reset']}; "
    end
    raise ReleaseStorage::StorageError, "GitHub #{action} failed: #{detail}HTTP #{response.status}"
  end

  # Signed download URLs carry credentials in the query string; keep them
  # out of exception messages and logs.
  def redact(url)
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}#{uri.path}"
  rescue URI::InvalidURIError
    '[unparseable url]'
  end
end
