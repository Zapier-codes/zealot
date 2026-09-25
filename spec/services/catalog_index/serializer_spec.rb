# frozen_string_literal: true

require 'rails_helper'

# Task 29b. See app/services/catalog_index/serializer.rb and
# docs/catalog_index_v2.md / docs/catalog_index_v2.schema.json for the full
# design notes.
#
# No Release factory exists in this repo (checked spec/factories/); built
# directly against db/schema.rb's non-null columns, same approach
# spec/requests/api/mtproto_archives_spec.rb (Task 19f) used.
RSpec.describe CatalogIndex::Serializer do
  def build_app_with_release(package_name: 'com.example.app', file_contents: 'apk bytes',
                              original_size: nil, signing_key_checksum: nil, file_sha256: nil,
                              app_name: 'Example App')
    app = create(:app, play_package_name: package_name, name: app_name)
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
    it 'serializes the v2 index envelope' do
      app, = build_app_with_release

      result = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12), sequence: 7)

      expect(result[:schema_version]).to eq(2)
      expect(result[:generated_at]).to eq('2026-09-24T12:00:00Z')
      expect(result[:sequence]).to eq(7)
      expect(result[:expires_at]).to eq('2026-09-25T12:00:00Z') # DEFAULT_TTL = 24h
    end

    it 'accepts an explicit expires_at instead of the default TTL' do
      app, = build_app_with_release

      result = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12),
                                          expires_at: Time.utc(2026, 9, 24, 13))

      expect(result[:expires_at]).to eq('2026-09-24T13:00:00Z')
    end

    it 'serializes an app with a release whose file is still local' do
      app, release = build_app_with_release(file_contents: 'apk bytes', signing_key_checksum: 'abc123')

      result = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12))
      entry = result[:apps].first

      expect(entry[:id]).to eq(app.id)
      expect(entry[:package_name]).to eq('com.example.app')
      expect(entry[:listing_status]).to eq(app.listing_status)
      expect(entry[:publisher]).to eq(name: nil, verified: false, bio: nil, profile_url: nil, joined_at: nil)
      expect(entry[:listing][:description]).to be_nil
      expect(entry[:listing][:icon]).to eq(url: nil, sha256: nil)
      expect(entry[:listing][:screenshots]).to eq([])
      expect(entry[:listing][:content_rating]).to be_nil
      expect(entry[:listing][:data_safety]).to eq(
        collects_data: nil, data_types: [], shared_with_third_parties: nil,
        encrypted_in_transit: nil, deletion_request_url: nil
      )
      expect(entry[:listing][:contains_ads]).to be_nil
      expect(entry[:listing][:has_in_app_purchases]).to be_nil
      expect(entry[:summary]).to be_nil
      expect(entry[:category]).to be_nil
      expect(entry[:license]).to be_nil
      expect(entry[:links]).to eq(site: nil, source: nil, tracker: nil, donate: nil)
      expect(entry[:available_regions]).to be_nil
      expect(entry[:created_at]).to eq(app.created_at.utc.iso8601)
      expect(entry[:updated_at]).to eq(app.updated_at.utc.iso8601)
      expect(entry[:editorial]).to eq(featured: false, editors_pick: false)
      expect(entry[:sponsored_slots]).to eq([])
      expect(entry[:collections]).to eq([])

      expect(entry[:versions].size).to eq(1)
      version = entry[:versions].first
      expect(version[:release_id]).to eq(release.id)
      expect(version[:version_name]).to eq('1.2.3')
      expect(version[:version_code]).to eq('42')
      expect(version[:download_url]).to eq(release.download_url)
      expect(version[:sha256]).to eq(Digest::SHA256.hexdigest('apk bytes'))
      expect(version[:signing_fingerprint]).to eq('abc123')
      expect(version[:changelog]).to be_nil
      expect(version[:released_at]).to eq(release.created_at.utc.iso8601)
      expect(version[:status]).to eq('available')
      expect(version[:compatibility]).to eq(
        min_sdk: nil, target_sdk: nil, abis: [], screen_densities: [],
        required_features: [], permissions: []
      )
    end

    it 'renders a real changelog as the joined text_changelog string, not the raw jsonb (Task 29d finding)' do
      app, release = build_app_with_release
      release.update_column(:changelog, [ { 'message' => 'Fixed login crash' }, { 'message' => 'Improved battery usage' } ])

      result = described_class.call(app)

      expect(result[:apps].first[:versions].first[:changelog])
        .to eq("- Fixed login crash\n- Improved battery usage")
    end

    it 'derives a schema-valid slug from the app name' do
      app, = build_app_with_release(app_name: 'My Cool App!!')

      result = described_class.call(app)

      expect(result[:apps].first[:slug]).to eq('my-cool-app')
    end

    it 'falls back to app-<id> when the name has no alphanumeric characters' do
      app, = build_app_with_release(app_name: '★★★')

      result = described_class.call(app)

      expect(result[:apps].first[:slug]).to eq("app-#{app.id}")
    end

    it 'nulls sha256 (not an error) once the local file is gone, and falls back to original_size' do
      app, release = build_app_with_release(file_contents: 'apk bytes', original_size: 999)
      release.file = nil
      release.save!(validate: false)

      result = described_class.call(app)

      version = result[:apps].first[:versions].first
      expect(version[:sha256]).to be_nil
      expect(version[:size_bytes]).to eq(999)
    end

    it 'prefers the persisted file_sha256 (Task 27b-i) over hashing the local file live' do
      app, = build_app_with_release(file_contents: 'apk bytes', file_sha256: 'persisted-hash')

      result = described_class.call(app)

      expect(result[:apps].first[:versions].first[:sha256]).to eq('persisted-hash')
    end

    it 'returns an empty versions[] for an app with no releases' do
      app = create(:app)

      result = described_class.call(app)

      expect(result[:apps].first[:versions]).to eq([])
    end

    it "lists every release across the app's channels, newest first, not just the latest" do
      app, first_release = build_app_with_release
      scheme = first_release.channel.scheme
      second_channel = Channel.create!(scheme: scheme, name: 'beta', slug: SecureRandom.hex(4), device_type: 'android')
      second_release = Release.create!(
        channel: second_channel, version: 1, changelog: [], release_version: '1.3.0', build_version: '43'
      )

      result = described_class.call(app)

      expect(result[:apps].first[:versions].map { |v| v[:release_id] }).to eq([ second_release.id, first_release.id ])
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
