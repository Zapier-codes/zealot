# frozen_string_literal: true

# Task 31b (slice 31b-a): the read-only client for D-store's stats endpoint.
#
# D-store owns traffic, searches, reports and review aggregates in its own
# Supabase database and exposes them as ONE JSON document at
# `GET <DSTORE_STATS_URL>` (D-store leaf 5.g.v.zo, `app/api/stats`),
# guarded by a bearer token that can only read that document. This service is
# the Zealot side of that contract: it fetches the document, checks its shape
# and hands the admin view a plain Hash. It never writes to D-store (Task 31c
# keeps moderation actions in D-store, so Zealot holds no write path).
#
# Config (ENV, both required; unset is "not configured", never a guess):
#   DSTORE_STATS_URL    full URL of the endpoint, https (http only for
#                       localhost/127.0.0.1, for a local D-store)
#   DSTORE_STATS_TOKEN  the bearer token D-store checks against its
#                       STATS_READ_TOKEN. Held server-side only; never put in a
#                       view, a log line, a flash or an error message.
#
#   result = DstoreStats.fetch
#   result.ok?     # => true when `result.stats` is a validated document
#   result.status  # => :ok, :not_configured, :unauthorized, :unavailable, :invalid
#
# The contract (all counts are JSON numbers; see D-store's
# supabase/migrations/20260930100200_store_stats_fn.sql):
#   generated_at
#   traffic  { total_installs, total_views, apps_tracked,
#              per_app: [ { slug, install_count, view_count } ] }
#   searches { total, distinct_queries, top: [ { query, count } ] }
#   reports  { total, by_status: { name => n }, by_reason: { name => n } }
#   reviews  { total, average_rating (null when there are none),
#              per_app: [ { slug, count, average_rating } ] }
# No review text, no hashes, no report details and no per-search times arrive,
# and this service would drop them if they did: only the keys above are kept.
module DstoreStats
  MAX_BODY_BYTES = 1_048_576
  OPEN_TIMEOUT = 5
  TIMEOUT = 10

  Result = Struct.new(:status, :stats, keyword_init: true) do
    def ok?
      status == :ok
    end
  end

  class << self
    def url
      ENV['DSTORE_STATS_URL'].to_s.strip.presence
    end

    def token
      ENV['DSTORE_STATS_TOKEN'].to_s.strip.presence
    end

    def configured?
      valid_url?(url) && token.present?
    end

    # One GET, no retry, no redirect following. Never raises.
    def fetch
      return Result.new(status: :not_configured) unless configured?

      response = connection.get
      status = response.status.to_i
      return Result.new(status: :unauthorized) if [401, 403].include?(status)
      return Result.new(status: :unavailable) unless status == 200
      return Result.new(status: :invalid) if response.body.to_s.bytesize > MAX_BODY_BYTES

      stats = Document.parse(JSON.parse(response.body.to_s))
      stats ? Result.new(status: :ok, stats: stats) : Result.new(status: :invalid)
    rescue JSON::ParserError
      Result.new(status: :invalid)
    rescue Faraday::Error
      Result.new(status: :unavailable)
    end

    private

    def valid_url?(value)
      return false if value.blank?

      uri = URI.parse(value)
      return false unless uri.host.present?

      uri.scheme == 'https' || (uri.scheme == 'http' && %w[localhost 127.0.0.1].include?(uri.host))
    rescue URI::InvalidURIError
      false
    end

    def connection
      Faraday.new(
        url: url,
        headers: {
          'Authorization' => "Bearer #{token}",
          'Accept' => 'application/json',
          'User-Agent' => 'Zealot'
        },
        request: { open_timeout: OPEN_TIMEOUT, timeout: TIMEOUT }
      )
    end
  end

  # Checks the document against the contract above and returns a NEW Hash that
  # holds only the contract's keys, or nil if anything is the wrong type.
  # Pure: no I/O, so it is tested without a network.
  module Document
    module_function

    def parse(json)
      return nil unless json.is_a?(Hash)

      traffic = traffic(json['traffic'])
      searches = searches(json['searches'])
      reports = reports(json['reports'])
      reviews = reviews(json['reviews'])
      generated_at = json['generated_at']
      return nil unless generated_at.is_a?(String) && [traffic, searches, reports, reviews].all?

      { generated_at: generated_at, traffic: traffic, searches: searches, reports: reports, reviews: reviews }
    end

    def count?(value)
      value.is_a?(Integer) && value >= 0
    end

    def rating?(value)
      value.nil? || (value.is_a?(Numeric) && value >= 0 && value <= 5)
    end

    def rows(list)
      return nil unless list.is_a?(Array)

      mapped = list.map { |row| row.is_a?(Hash) ? yield(row) : nil }
      mapped.all? ? mapped : nil
    end

    def tally(hash)
      return nil unless hash.is_a?(Hash) && hash.all? { |k, v| k.is_a?(String) && count?(v) }

      hash.dup
    end

    def traffic(node)
      return nil unless node.is_a?(Hash) && %w[total_installs total_views apps_tracked].all? { |k| count?(node[k]) }

      per_app = rows(node['per_app']) do |r|
        next nil unless r['slug'].is_a?(String) && count?(r['install_count']) && count?(r['view_count'])

        { slug: r['slug'], install_count: r['install_count'], view_count: r['view_count'] }
      end
      return nil unless per_app

      { total_installs: node['total_installs'], total_views: node['total_views'],
        apps_tracked: node['apps_tracked'], per_app: per_app }
    end

    def searches(node)
      return nil unless node.is_a?(Hash) && count?(node['total']) && count?(node['distinct_queries'])

      top = rows(node['top']) do |r|
        r['query'].is_a?(String) && count?(r['count']) ? { query: r['query'], count: r['count'] } : nil
      end
      top ? { total: node['total'], distinct_queries: node['distinct_queries'], top: top } : nil
    end

    def reports(node)
      return nil unless node.is_a?(Hash) && count?(node['total'])

      by_status = tally(node['by_status'])
      by_reason = tally(node['by_reason'])
      by_status && by_reason ? { total: node['total'], by_status: by_status, by_reason: by_reason } : nil
    end

    def reviews(node)
      return nil unless node.is_a?(Hash) && count?(node['total']) && rating?(node['average_rating'])

      per_app = rows(node['per_app']) do |r|
        next nil unless r['slug'].is_a?(String) && count?(r['count']) && rating?(r['average_rating'])

        { slug: r['slug'], count: r['count'], average_rating: r['average_rating'] }
      end
      return nil unless per_app

      { total: node['total'], average_rating: node['average_rating'], per_app: per_app }
    end
  end
end
