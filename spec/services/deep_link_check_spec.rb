# frozen_string_literal: true

require 'rails_helper'

# Z-P22: DeepLinkCheck gathers the package, the signing-certificate SHA-256 and the declared hosts from
# what Zealot already stores, then asks AssetLinks::Verifier once per host. The verifier is injected as a
# fake here, so this spec exercises the gathering and the per-host reporting without any request.
RSpec.describe DeepLinkCheck do
  let(:fingerprint) { 'AB:CD:EF:01:23:45' }
  let(:recorded) { [] }

  # Records each call and answers with a canned state.
  let(:fake_verifier) do
    recorder = recorded
    Class.new do
      define_method(:call) do |host:, package_name:, sha256:, adapter: nil|
        recorder << { host: host, package_name: package_name, sha256: sha256 }
        AssetLinks::Verifier::Result.new(
          state: AssetLinks::Verifier::STATE_VERIFIED,
          entries: [],
          http_status: 200
        )
      end
    end.new
  end

  def app_with_release(package_name: 'com.example.app', deep_links: [], certs: nil)
    app = create(:app, play_package_name: package_name)
    scheme = Scheme.create!(app: app, name: 'production')
    channel = Channel.create!(scheme: scheme, name: 'stable', slug: SecureRandom.hex(4), device_type: 'Android')
    release = Release.create!(
      channel: channel, version: 1, changelog: [], release_version: '1.0.0', build_version: '1'
    )
    release.create_metadata!(
      checksum: SecureRandom.hex(8), device: 'Android', deep_links: deep_links,
      developer_certs: certs || default_certs
    )
    [app, release]
  end

  def default_certs
    [
      {
        'scheme' => 2,
        'certificates' => [
          { 'fingerprint' => { 'md5' => 'AA:BB', 'sha1' => 'CC:DD', 'sha256' => fingerprint } }
        ]
      }
    ]
  end

  describe 'gathering' do
    it 'reads the package from the app, the certificate from the release and the hosts from deep links' do
      app, = app_with_release(deep_links: [ { 'host' => 'example.com' }, 'https://open.example.com/thing' ])

      result = described_class.new(app, verifier: fake_verifier).call

      expect(result.package_name).to eq('com.example.app')
      expect(result.sha256).to eq(fingerprint)
      expect(result.hosts).to contain_exactly('example.com', 'open.example.com')
      expect(result.runnable?).to be(true)
    end

    it 'falls back to the release bundle_id when the app has no play_package_name' do
      app, release = app_with_release(package_name: nil, deep_links: [ { 'host' => 'example.com' } ])
      release.update!(bundle_id: 'com.from.bundle')

      expect(described_class.new(app, verifier: fake_verifier).package_name).to eq('com.from.bundle')
    end

    it 'reports no certificate when the release carries none' do
      app, = app_with_release(deep_links: [ { 'host' => 'example.com' } ], certs: [])

      expect(described_class.new(app, verifier: fake_verifier).sha256).to be_nil
    end

    it 'reports no hosts when the deep links declare none' do
      app, = app_with_release(deep_links: [])

      expect(described_class.new(app, verifier: fake_verifier).hosts).to eq([])
    end
  end

  describe 'checking' do
    it 'runs the verifier once per host with the package and certificate' do
      app, = app_with_release(deep_links: [ { 'host' => 'a.example.com' }, { 'host' => 'b.example.com' } ])

      result = described_class.new(app, verifier: fake_verifier).call

      expect(result.hosts.map(&:host)).to eq(%w[a.example.com b.example.com])
      expect(result.hosts).to all(be_verified)
      expect(recorded.map { |c| c[:package_name] }.uniq).to eq(['com.example.app'])
      expect(recorded.map { |c| c[:sha256] }.uniq).to eq([fingerprint])
    end

    it 'is not runnable and does not call the verifier when nothing is there to check' do
      app, = app_with_release(deep_links: [ { 'host' => 'example.com' } ], certs: [])

      result = described_class.new(app, verifier: fake_verifier).call

      expect(result.runnable?).to be(false)
      expect(recorded).to be_empty
    end
  end
end
