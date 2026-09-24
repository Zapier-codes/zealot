# frozen_string_literal: true

require 'rails_helper'

# Task 27a. See app/services/catalog_index/serializer.rb and
# docs/catalog_index_v1.md for the full design notes -- in particular the
# "sha256 gap" section, which this spec's second example exercises (no
# local file -> null, not an error).
#
# No Release factory exists in this repo (checked spec/factories/); built
# directly against db/schema.rb's non-null columns, same approach
# spec/requests/api/mtproto_archives_spec.rb (Task 19f) used.
RSpec.describe CatalogIndex::Serializer do
  def build_app_with_release(package_name: 'com.example.app', file_contents: 'apk bytes',
                              original_size: nil, signing_key_checksum: nil, file_sha256: nil)
    app = create(:app, play_package_name: package_name)
    scheme = Scheme.create!(app: app, name: 'production')
    channel = Channel.create!(scheme: scheme, name: 'stable', slug: SecureRandom.hex(4), device_type: 'android')
    release = Release.new(
      channel: channel,
      version: 1,
      changelog: [],
      release_version: '1.2.3',
      build_version: '42',
      original_size: original_size,
      signing_key_checksum: signing_key_checksum,
      file_sha256: file_sha256
    )

    if file_contents
      Tempfile.create([ 'release', '.apk' ]) do |tmp|
        tmp.write(file_contents)
        tmp.flush
        release.file = File.open(tmp.path)
        release.save!(validate: false)
      end
    else
      release.save!(validate: false)
    end

    [ app, release ]
  end

  describe '.call' do
    it 'serializes an app with a release whose file is still local' do
      app, release = build_app_with_release(file_contents: 'apk bytes', signing_key_checksum: 'abc123')

      result = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12))

      expect(result[:schema_version]).to eq(1)
      expect(result[:generated_at]).to eq('2026-09-24T12:00:00Z')

      entry = result[:apps].first
      expect(entry[:id]).to eq(app.id)
      expect(entry[:package_name]).to eq('com.example.app')
      expect(entry[:publisher]).to eq(name: nil, verified: false)
      expect(entry[:listing][:description]).to be_nil
      expect(entry[:listing][:icon]).to eq(url: nil, sha256: nil)
      expect(entry[:listing][:screenshots]).to eq([])

      lv = entry[:latest_version]
      expect(lv[:release_id]).to eq(release.id)
      expect(lv[:version_name]).to eq('1.2.3')
      expect(lv[:version_code]).to eq('42')
      expect(lv[:download_url]).to eq(release.download_url)
      expect(lv[:sha256]).to eq(Digest::SHA256.hexdigest('apk bytes'))
      expect(lv[:signing_fingerprint]).to eq('abc123')
    end

    it 'nulls sha256 (not an error) once the local file is gone, and falls back to original_size' do
      _app, release = build_app_with_release(file_contents: 'apk bytes', original_size: 999)
      release.file = nil
      release.save!(validate: false)

      result = described_class.call(release.channel.scheme.app)

      lv = result[:apps].first[:latest_version]
      expect(lv[:sha256]).to be_nil
      expect(lv[:size_bytes]).to eq(999)
    end

    it 'prefers the persisted file_sha256 (Task 27b-i) over hashing the local file live' do
      _app, release = build_app_with_release(file_contents: 'apk bytes', file_sha256: 'persisted-hash')

      result = described_class.call(release.channel.scheme.app)

      expect(result[:apps].first[:latest_version][:sha256]).to eq('persisted-hash')
    end

    it 'still returns sha256 once the local file is gone if it was persisted at mirror time' do
      _app, release = build_app_with_release(file_contents: 'apk bytes', file_sha256: 'persisted-hash')
      release.file = nil
      release.save!(validate: false)

      result = described_class.call(release.channel.scheme.app)

      expect(result[:apps].first[:latest_version][:sha256]).to eq('persisted-hash')
    end

    it 'returns a nil latest_version for an app with no releases' do
      app = create(:app)

      result = described_class.call(app)

      expect(result[:apps].first[:latest_version]).to be_nil
    end

    it 'accepts a single app as well as an enumerable of apps' do
      app, = build_app_with_release
      result = described_class.call(app)

      expect(result[:apps].size).to eq(1)
    end
  end

  describe '.for_live_apps' do
    it 'only includes apps whose listing_status is live' do
      live_app = create(:app, listing_status: :live)
      create(:app, listing_status: :draft)

      result = described_class.for_live_apps

      expect(result[:apps].map { |a| a[:id] }).to eq([ live_app.id ])
    end
  end
end
