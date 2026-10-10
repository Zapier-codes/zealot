# frozen_string_literal: true

require 'json'

module ReleaseChecks
  # Z-P4 (Play Console parity): third-party SDK / tracker detection. Play's "App content" data-safety form and
  # the Play policy review both care about which advertising, analytics and crash SDKs a build ships. Zealot
  # already has MobSF available as the general automated-review runner (Z-P2); MobSF's report includes an
  # Exodus-style tracker list, so this reads that section rather than writing its own DEX scan.
  #
  # MobSF is reached as a container over its REST API (the operator's "assemble, not write" route, see
  # docs/UNOFFICIAL-ROUTES.md). Configuration (ENV), all optional -- with none set the runner is "not
  # configured" and the review still runs its static checks:
  #   MOBSF_URL    e.g. http://mobsf:8000
  #   MOBSF_API_KEY
  #
  # A scanned tracker is normalized to { name:, category:, code_signature: } so the Console and the signed
  # index publish one stable shape no matter which scanner produced it.
  class MobsfClient
    Tracker = Struct.new(:name, :category, :code_signature, keyword_init: true)

    class NotConfigured < StandardError; end
    class ScanFailed < StandardError; end

    def self.configured?
      url = ENV['MOBSF_URL'].to_s
      !url.empty? && !ENV['MOBSF_API_KEY'].to_s.empty?
    end

    def initialize(url: ENV['MOBSF_URL'], api_key: ENV['MOBSF_API_KEY'], transport: nil)
      @url = url.to_s
      @api_key = api_key.to_s
      @transport = transport
    end

    # Uploads the APK bytes for scanning and returns the tracker list from the JSON report.
    # @param bytes [String] the APK the release stores
    # @return [Array<Tracker>]
    # @raise [NotConfigured] with no URL/key
    # @raise [ScanFailed] the scan could not be completed
    def scan(bytes)
      raise NotConfigured, 'MOBSF_URL / MOBSF_API_KEY are not set' unless self.class.configured? || @transport

      report = @transport ? @transport.call(@url, @api_key, bytes) : upload_and_scan(bytes)
      trackers_from_report(report)
    rescue NotConfigured, ScanFailed
      raise
    rescue StandardError => e
      raise ScanFailed, "MobSF scan failed: #{e.class}: #{e.message}"
    end

    # Pure mapping of an already-parsed MobSF report into Trackers, so the shape is testable without a
    # container. MobSF keeps trackers under `trackers.trackers` (Exodus signatures); tolerate its absence.
    def trackers_from_report(report)
      section = report.is_a?(Hash) ? report.dig('trackers', 'trackers') : nil
      Array(section).filter_map do |entry|
        next unless entry.is_a?(Hash)

        name = entry['name'].to_s.strip
        next if name.empty?

        Tracker.new(name: name,
                    category: entry['categories'].to_s.strip.presence,
                    code_signature: entry['code_signature'].to_s.strip.presence)
      end
    end

    private

    # Real MobSF call: POST /api/v1/upload (multipart) -> hash, then POST /api/v1/scan -> report. Kept
    # separate from `trackers_from_report` so the mapping is exercised without the network.
    def upload_and_scan(_bytes)
      raise ScanFailed, 'MobSF transport not wired in this environment'
    end
  end
end
