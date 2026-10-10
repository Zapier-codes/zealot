# frozen_string_literal: true

require 'uri'

# Z-P22: one deep-link verification check for one app, gathered from what Zealot already stores.
#
# Where the inputs come from (no new columns, no guessing):
#   package     app.play_package_name, else the newest Android release's bundle_id
#   certificate the newest Android release's teardown metadata carries every signing cert with
#               md5/sha1/sha256 fingerprints (TeardownService#process_signature_certs); the first
#               sha256 present is the one the well-known file must name
#   hosts       every distinct host declared by an Android release's `metadata.deep_links` entries
#               (`host`/`domain` keys, or parsed from a URL string)
#
# It runs AssetLinks::Verifier once per host and reports a per-host result. An app with no host, no
# package or no certificate is reported as such rather than sent to the network.
class DeepLinkCheck
  HostResult = Struct.new(:host, :state, :http_status, keyword_init: true) do
    def verified?
      state == AssetLinks::Verifier::STATE_VERIFIED
    end
  end

  Result = Struct.new(:package_name, :sha256, :declared_hosts, :hosts, keyword_init: true) do
    def any_host?
      hosts.any?
    end

    def verified?
      hosts.any?(&:verified?)
    end

    def all_verified?
      hosts.any? && hosts.all?(&:verified?)
    end

    # The network check needs all three inputs; otherwise the page reports what is missing and no
    # request is made.
    def runnable?
      package_name.present? && sha256.present? && declared_hosts.any?
    end
  end

  # `adapter` lets a spec pass a Faraday test adapter through to the verifier.
  def initialize(app, verifier: AssetLinks::Verifier, adapter: nil)
    @app = app
    @verifier = verifier
    @adapter = adapter
  end

  def call
    hosts = declared_hosts
    results = runnable_inputs? ? checked(hosts) : []
    Result.new(package_name: package_name, sha256: sha256, declared_hosts: hosts, hosts: results)
  end

  def package_name
    @app.play_package_name.presence || newest_android_release&.bundle_id.presence
  end

  def sha256
    cert = newest_android_release&.metadata&.developer_certs
    extract_sha256(cert)
  end

  def declared_hosts
    android_releases.flat_map { |release| hosts_for_release(release) }.compact.uniq
  end

  private

  def runnable_inputs?
    package_name.present? && sha256.present? && declared_hosts.any?
  end

  def checked(hosts)
    hosts.map do |host|
      result = @verifier.call(host: host, package_name: package_name.to_s, sha256: sha256.to_s, adapter: @adapter)
      HostResult.new(host: host, state: result.state, http_status: result.http_status)
    end
  end

  def android_releases
    @android_releases ||= begin
      releases = @app.schemes.flat_map { |scheme| scheme.channels }.select { |c| c.device_type == 'Android' }
                     .flat_map(&:releases)
      releases.sort_by { |r| r.created_at || Time.at(0) }.reverse
    end
  end

  def newest_android_release
    android_releases.first
  end

  def extract_sha256(developer_certs)
    Array(developer_certs).each do |signature|
      Array(signature['certificates'] || signature[:certificates]).each do |cert|
        fp = cert['fingerprint'] || cert[:fingerprint]
        value = fp.is_a?(Hash) ? (fp['sha256'] || fp[:sha256]) : nil
        return value if value.present?
      end
    end
    nil
  end

  # A deep_links entry is either a Hash with an explicit host/domain, or a String URL. Anything else is
  # skipped. `www.` is kept: the file lives on the exact host the link declares.
  def hosts_for_release(release)
    Array(release.metadata&.deep_links).filter_map do |entry|
      case entry
      when Hash
        (entry['host'] || entry['domain'] || entry[:host] || entry[:domain]).presence
      when String
        URL.host_for(entry)
      end
    end
  end

  # Kept here (not AssetLinks::Verifier) because it is only used while parsing stored teardown data, not
  # while checking a live host.
  module URL
    module_function

    def host_for(value)
      text = value.to_s.strip
      return nil if text.blank?

      uri = URI.parse(text.match?(%r{\A[a-z][a-z0-9+.-]*://}i) ? text : "https://#{text}")
      uri.host&.downcase
    rescue URI::InvalidURIError
      nil
    end
  end
end
