# frozen_string_literal: true

require 'net/http'
require 'json'

# Cold-storage archival of our own large release artifacts into Telegram via
# MTProto, sitting behind ReleaseStorage's R2 adapter as a cheaper long-term
# tier for builds that are old/large and rarely downloaded.
#
# IMPORTANT — scope (see handover.md "Scope, stated plainly"): this archives
# only our own build artifacts that already live in our own R2 bucket. It
# does not touch, re-host, or re-distribute any third-party content.
#
# Rails does not speak MTProto directly. The actual protocol handshake,
# session/auth-key management, and chunked upload.getFile / upload.saveFile
# calls are delegated to a small Node/GramJS sidecar worker (see
# `mtproto-worker/`), the same approach documented in the `aetheroll`
# reference repo (docs/CACHING_AND_DATA_FETCHING_ARCHITECTURE.md — 512KB
# chunking, persistent warm connection pool). This service is just an HTTP
# client for that sidecar; it holds no cryptographic material itself.
#
# Required env vars:
#   MTPROTO_WORKER_URL           - e.g. http://mtproto-worker:8081
#   MTPROTO_WORKER_SHARED_SECRET - bearer token authenticating Rails -> worker
#                                   (the worker in turn holds the actual
#                                   TELEGRAM_API_ID/HASH/SESSION_STRING; those
#                                   never touch the Rails process)
#
# Usage:
#   svc = Anthropic::MtprotoArchiveService.new
#   location = svc.archive(local_path, key: "uploads/apps/a1/r42/release.apks.br")
#   svc.retrieve(location, to: local_path)
class Anthropic::MtprotoArchiveService
  class ConfigurationError < StandardError; end
  class ArchiveError < StandardError; end

  REQUIRED_ENV = %w[MTPROTO_WORKER_URL MTPROTO_WORKER_SHARED_SECRET].freeze

  def self.enabled?
    ENV['MTPROTO_ARCHIVE_ENABLED'] == 'true'
  end

  def initialize(worker_url: ENV['MTPROTO_WORKER_URL'], shared_secret: ENV['MTPROTO_WORKER_SHARED_SECRET'])
    ensure_configured!
    @worker_url = worker_url
    @shared_secret = shared_secret
  end

  # Uploads `local_path` to the Telegram-backed archive tier and returns an
  # opaque location string (worker-defined; e.g. "channel_id:message_id")
  # to persist on the release (`mtproto_archived_location`).
  def archive(local_path, key:)
    uri = worker_uri('/archive')
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@shared_secret}"
    request['X-Archive-Key'] = key
    request.body = File.binread(local_path)
    request['Content-Type'] = 'application/octet-stream'

    response = perform(uri, request)
    raise ArchiveError, "archive failed for #{key}: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)['location']
  end

  # Streams the archived file identified by `location` down to `to` (a
  # local path). Returns `to`, or nil if the worker reports it can't find
  # the archived message (e.g. deleted upstream).
  def retrieve(location, to:)
    uri = worker_uri('/retrieve')
    uri.query = URI.encode_www_form(location: location)
    request = Net::HTTP::Get.new(uri)
    request['Authorization'] = "Bearer #{@shared_secret}"

    FileUtils.mkdir_p(File.dirname(to))
    response = perform(uri, request) { |res| stream_body(res, to) }

    case response
    when Net::HTTPSuccess then to
    when Net::HTTPNotFound then nil
    else
      raise ArchiveError, "retrieve failed for #{location}: #{response.code} #{response.body}"
    end
  end

  private

  def worker_uri(path)
    URI.join(@worker_url, path)
  end

  def perform(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) do |http|
      if block_given?
        http.request(request) { |response| yield response; response }
      else
        http.request(request)
      end
    end
  rescue StandardError => e
    raise ArchiveError, "mtproto worker request failed: #{e.message}"
  end

  def stream_body(response, to)
    return unless response.is_a?(Net::HTTPSuccess)

    File.open(to, 'wb') do |file|
      response.read_body { |chunk| file.write(chunk) }
    end
  end

  def ensure_configured!
    missing = REQUIRED_ENV.select { |var| ENV[var].blank? }
    return if missing.empty?

    raise ConfigurationError, "MTProto archive selected but missing env vars: #{missing.join(', ')}"
  end
end
