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
  # The json-schema gem (6.x) cannot load the 2020-12 meta-schema this document names: skip rather than fail.
  def validate_against(schema, document)
    JSON::Validator.fully_validate(schema, document)
  rescue JSON::Schema::SchemaError => e
    skip "JSON::Validator cannot load this schema draft (#{e.message})"
  end

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
      expect(result[:expires_at]).to eq('2026-09-26T12:00:00Z') # DEFAULT_TTL = 48h (Task 49)
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

    describe 'a release CI has compiled (Task 40e)' do
      let(:apk_sha) { 'd' * 64 }

      it 'advertises the universal APK\'s hash and size, not the bundle\'s or the old split set\'s' do
        app, release = build_app_with_release(file_contents: 'aab bytes', original_size: 999,
                                              file_sha256: Digest::SHA256.hexdigest('aab bytes'))
        release.update_columns(ci_compile_state: 'done',
                               universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/universal.apk',
                               universal_apk_sha256: apk_sha, universal_apk_size: 4321)

        version = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12))[:apps].first[:versions].first

        expect(version[:sha256]).to eq(apk_sha)
        expect(version[:size_bytes]).to eq(4321)
      end

      it 'keeps the bundle\'s values while the compile is not done' do
        app, release = build_app_with_release(file_contents: 'aab bytes', original_size: 999,
                                              file_sha256: Digest::SHA256.hexdigest('aab bytes'))
        release.update_columns(ci_compile_state: 'dispatched', universal_apk_sha256: apk_sha, universal_apk_size: 4321)

        version = described_class.call(app, generated_at: Time.utc(2026, 9, 24, 12))[:apps].first[:versions].first

        expect(version[:sha256]).to eq(Digest::SHA256.hexdigest('aab bytes'))
        expect(version[:size_bytes]).to eq(999)
      end
    end

    describe 'listing.icon (Task 27d-c)' do
      let(:sha) { 'a' * 64 }

      def icon_of(app)
        described_class.call(app)[:apps].first[:listing][:icon]
      end

      it 'stays empty for a release with no icon anywhere' do
        app, = build_app_with_release

        expect(icon_of(app)).to eq(url: nil, sha256: nil)
      end

      it 'points at the stable icon endpoint with the recorded hash once the icon is mirrored' do
        app, release = build_app_with_release
        release.update_columns(icon_storage_key: 'uploads/apps/a1/r1/icons/icon.png', icon_sha256: sha)

        expect(icon_of(app)).to eq(url: release.icon_download_url, sha256: sha)
        expect(release.icon_download_url).to end_with("/download/releases/#{release.id}/icon")
      end

      it 'hashes the local icon when the mirror job has not recorded a hash yet' do
        app, release = build_app_with_release
        Tempfile.create([ 'icon', '.png' ]) do |tmp|
          tmp.write('png bytes')
          tmp.flush
          allow_any_instance_of(Release).to receive(:icon).and_return(double(path: tmp.path))

          expect(icon_of(app)).to eq(url: release.icon_download_url, sha256: Digest::SHA256.hexdigest('png bytes'))
        end
      end

      it 'advertises the URL with a null hash when only a storage key exists' do
        app, release = build_app_with_release
        release.update_columns(icon_storage_key: 'uploads/apps/a1/r1/icons/icon.png')

        expect(icon_of(app)).to eq(url: release.icon_download_url, sha256: nil)
      end

      it 'falls back to the newest older release that has an icon' do
        app, older = build_app_with_release
        older.update_columns(icon_storage_key: 'k', icon_sha256: sha, created_at: 2.days.ago)
        newer = Release.new(channel: older.channel, version: 2, changelog: [], release_version: '1.2.4',
                            build_version: '43')
        newer.save!(validate: false)

        expect(icon_of(app)).to eq(url: older.icon_download_url, sha256: sha)
      end

      it 'prefers the newest release when it has an icon' do
        app, older = build_app_with_release
        older.update_columns(icon_storage_key: 'k1', icon_sha256: sha, created_at: 2.days.ago)
        newer = Release.new(channel: older.channel, version: 2, changelog: [], release_version: '1.2.4',
                            build_version: '43')
        newer.save!(validate: false)
        newer.update_columns(icon_storage_key: 'k2', icon_sha256: 'b' * 64)

        expect(icon_of(app)).to eq(url: newer.icon_download_url, sha256: 'b' * 64)
      end

      it 'ignores the icon of a held release (it is not in versions[] at all)' do
        app, release = build_app_with_release
        release.update_columns(icon_storage_key: 'k', icon_sha256: sha, status: 'held')

        expect(icon_of(app)).to eq(url: nil, sha256: nil)
      end

      it 'gives a fixture that knows nothing about icons the empty value' do
        struct = Struct.new(:id, :play_package_name, :listing_status, :name, :created_at, :updated_at,
                            :publisher_display_name, :recently_release, keyword_init: true)
        fixture = struct.new(id: 1, play_package_name: 'x.y', listing_status: 'live', name: 'X',
                             created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 1))

        expect(icon_of(fixture)).to eq(url: nil, sha256: nil)
      end
    end

    describe 'listing graphics (Task 27d-e1)' do
      let(:sha) { 'a' * 64 }

      def listing_of(app)
        described_class.call(app)[:apps].first[:listing]
      end

      def add_graphic(app, overrides = {})
        @next_position = (@next_position || -1) + 1
        key = "uploads/apps/a#{app.id}/graphics/g#{@next_position}/graphic.png"
        ListingGraphic.create!({ app: app, kind: 'screenshot', device: 'phone', content_type: 'image/png',
                                 byte_size: 500_000, width: 1080, height: 1920, position: @next_position,
                                 sha256: sha, storage_key: key }.merge(overrides))
      end

      it 'keeps the empty values for an app with no graphics and no video' do
        app, = build_app_with_release

        expect(listing_of(app)).to include(screenshots: [], feature_graphic: nil, video: nil)
      end

      it 'lists screenshots in position order with url, hash, alt and size' do
        app, = build_app_with_release
        second = add_graphic(app, position: 1, alt_text: 'Second', sha256: 'b' * 64)
        first = add_graphic(app, position: 0, alt_text: nil)

        expect(listing_of(app)[:screenshots]).to eq(
          [
            { url: first.download_url, sha256: sha, alt: nil, width: 1080, height: 1920 },
            { url: second.download_url, sha256: 'b' * 64, alt: 'Second', width: 1080, height: 1920 }
          ]
        )
        expect(first.download_url).to end_with("/download/graphics/#{first.id}")
      end

      it 'leaves out a graphic that is not stored yet, or has no hash' do
        app, = build_app_with_release
        add_graphic(app, position: 0, storage_key: nil)
        add_graphic(app, position: 1, sha256: nil)
        kept = add_graphic(app, position: 2)

        expect(listing_of(app)[:screenshots].map { |shot| shot[:url] }).to eq([ kept.download_url ])
      end

      it 'carries the feature graphic apart from the screenshots' do
        app, = build_app_with_release
        banner = add_graphic(app, kind: 'feature_graphic', content_type: 'image/jpeg', width: 1024, height: 500,
                                  position: 0, alt_text: 'Banner')

        listing = listing_of(app)

        expect(listing[:feature_graphic]).to eq(url: banner.download_url, sha256: sha, alt: 'Banner')
        expect(listing[:screenshots]).to eq([])
      end

      it 'gives the feature graphic nothing until it is stored and hashed' do
        app, = build_app_with_release
        add_graphic(app, kind: 'feature_graphic', content_type: 'image/jpeg', width: 1024, height: 500,
                         position: 0, storage_key: nil)

        expect(listing_of(app)[:feature_graphic]).to be_nil
      end

      it 'carries the promo video as its YouTube ID only' do
        app, = build_app_with_release
        app.update_columns(promo_video_youtube_id: 'dQw4w9WgXcQ')

        expect(listing_of(app)[:video]).to eq(youtube_id: 'dQw4w9WgXcQ')
      end

      it 'does not list another app\'s graphics' do
        app, = build_app_with_release
        other, = build_app_with_release(package_name: 'com.example.other')
        add_graphic(other, position: 0)

        expect(listing_of(app)[:screenshots]).to eq([])
      end

      it 'gives a fixture that knows nothing about graphics the empty values' do
        struct = Struct.new(:id, :play_package_name, :listing_status, :name, :created_at, :updated_at,
                            :publisher_display_name, :recently_release, keyword_init: true)
        fixture = struct.new(id: 1, play_package_name: 'x.y', listing_status: 'live', name: 'X',
                             created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 1))

        expect(listing_of(fixture)).to include(screenshots: [], feature_graphic: nil, video: nil)
      end

      it 'produces a listing that validates against docs/catalog_index_v2.schema.json when a schema gem is loaded' do
        skip 'no JSON Schema library available' unless defined?(JSON::Validator)

        app, = build_app_with_release
        add_graphic(app, position: 0)
        app.update_columns(promo_video_youtube_id: 'dQw4w9WgXcQ')
        schema = Rails.root.join('docs/catalog_index_v2.schema.json').to_s

        document = JSON.parse(JSON.generate(described_class.call(app)))

        expect(validate_against(schema, document)).to eq([])
      end
    end

    describe 'listing text (Task 27e-a, 27e-b)' do
      def entry_of(app)
        described_class.call(app)[:apps].first
      end

      it 'emits nil for both when the owner has written nothing' do
        app, = build_app_with_release
        entry = entry_of(app)

        expect(entry[:listing][:description]).to be_nil
        expect(entry[:summary]).to be_nil
      end

      it 'emits the full description under listing and the short description as the top-level summary' do
        app, = build_app_with_release
        app.update_columns(description: "First paragraph.\n\nSecond paragraph.", short_description: 'Notes that stay out of your way')
        entry = entry_of(app)

        expect(entry[:listing][:description]).to eq("First paragraph.\n\nSecond paragraph.")
        expect(entry[:summary]).to eq('Notes that stay out of your way')
      end

      it 'does not mix the two fields up' do
        app, = build_app_with_release
        app.update_columns(description: 'long text', short_description: 'short text')
        entry = entry_of(app)

        expect(entry[:listing][:description]).not_to eq('short text')
        expect(entry[:summary]).not_to eq('long text')
      end

      it 'emits nil, never an empty string, for text that was saved blank around validation' do
        app, = build_app_with_release
        app.update_columns(description: '', short_description: '')
        entry = entry_of(app)

        expect(entry[:listing][:description]).to be_nil
        expect(entry[:summary]).to be_nil
      end

      it 'gives a fixture that knows nothing about listing text nil for both' do
        struct = Struct.new(:id, :play_package_name, :listing_status, :name, :created_at, :updated_at,
                            :publisher_display_name, :recently_release, keyword_init: true)
        fixture = struct.new(id: 1, play_package_name: 'x.y', listing_status: 'live', name: 'X',
                             created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 1))
        entry = entry_of(fixture)

        expect(entry[:listing][:description]).to be_nil
        expect(entry[:summary]).to be_nil
      end

      it 'produces an entry that validates against docs/catalog_index_v2.schema.json when a schema gem is loaded' do
        skip 'no JSON Schema library available' unless defined?(JSON::Validator)

        app, = build_app_with_release
        app.update_columns(description: 'a' * ListingText::DESCRIPTION_MAX_LENGTH,
                           short_description: 'a' * ListingText::SHORT_DESCRIPTION_MAX_LENGTH)
        schema = Rails.root.join('docs/catalog_index_v2.schema.json').to_s

        document = JSON.parse(JSON.generate(described_class.call(app)))

        expect(validate_against(schema, document)).to eq([])
      end
    end

    describe 'suggested_version_code (Task 27f-c)' do
      def suggested_of(app)
        described_class.call(app)[:apps].first[:suggested_version_code]
      end

      # `release` is the app's first release (build_version '42'); more are added on the same channel,
      # each newer than the last, so `App#catalog_releases` (newest first) lists them in call order.
      def add_release(after, build_version:, status: 'available')
        Release.new(channel: after.channel, version: build_version.to_i, changelog: [], release_version: "1.2.#{build_version}",
                    build_version: build_version, status: status, created_at: after.created_at + 1.hour)
               .tap { |added| added.save!(validate: false) }
      end

      it 'is the only available version code when there is one release' do
        app, = build_app_with_release

        expect(suggested_of(app)).to eq('42')
      end

      it 'is the highest available version code, compared as versions and not as strings' do
        app, release = build_app_with_release
        add_release(release, build_version: '100')
        add_release(release, build_version: '99')

        expect(suggested_of(app)).to eq('100')
      end

      it 'moves to the previous available release when the newest one is halted' do
        app, release = build_app_with_release
        add_release(release, build_version: '43', status: 'halted')

        expect(suggested_of(app)).to eq('42')
      end

      it 'moves to the previous available release when the newest one is pulled' do
        app, release = build_app_with_release
        add_release(release, build_version: '43', status: 'pulled')

        expect(suggested_of(app)).to eq('42')
      end

      it 'ignores a held release, which is not in the index at all' do
        app, release = build_app_with_release
        add_release(release, build_version: '43', status: 'held')

        expect(suggested_of(app)).to eq('42')
      end

      it 'is nil when no release is available' do
        app, release = build_app_with_release
        release.update_columns(status: 'halted')

        expect(suggested_of(app)).to be_nil
      end

      it 'is nil for an app with no releases' do
        app = create(:app, play_package_name: 'com.example.empty')

        expect(suggested_of(app)).to be_nil
      end

      it 'skips a release with a blank version code' do
        app, release = build_app_with_release
        add_release(release, build_version: '')

        expect(suggested_of(app)).to eq('42')
      end

      it 'is nil when the only release has a blank version code' do
        app, release = build_app_with_release
        release.update_columns(build_version: '')

        expect(suggested_of(app)).to be_nil
      end

      it 'keeps the newest release when two codes are equal as versions' do
        app, release = build_app_with_release
        release.update_columns(build_version: '1')
        add_release(release, build_version: '1.0')

        expect(suggested_of(app)).to eq('1.0')
      end

      it 'never lets a code that is not a version beat one that is' do
        app, release = build_app_with_release
        add_release(release, build_version: 'not a version')

        expect(suggested_of(app)).to eq('42')
      end

      it 'is nil for a fixture that knows nothing about releases' do
        struct = Struct.new(:id, :play_package_name, :listing_status, :name, :created_at, :updated_at,
                            :publisher_display_name, keyword_init: true)
        fixture = struct.new(id: 1, play_package_name: 'x.y', listing_status: 'live', name: 'X',
                             created_at: Time.utc(2026, 1, 1), updated_at: Time.utc(2026, 1, 1))

        expect(suggested_of(fixture)).to be_nil
      end

      it 'produces an entry that validates against docs/catalog_index_v2.schema.json when a schema gem is loaded' do
        skip 'no JSON Schema library available' unless defined?(JSON::Validator)

        app, release = build_app_with_release
        add_release(release, build_version: '43', status: 'pulled')
        schema = Rails.root.join('docs/catalog_index_v2.schema.json').to_s

        document = JSON.parse(JSON.generate(described_class.call(app)))

        expect(validate_against(schema, document)).to eq([])
      end
    end

    it 'reads real compatibility columns once Task 29c has populated them at upload time' do
      app, release = build_app_with_release
      release.update_columns(
        min_sdk_version: 24, target_sdk_version: 34,
        abis: [ 'arm64-v8a', 'armeabi-v7a' ], screen_densities: [ 'xhdpi', 'xxhdpi' ],
        required_features: [ 'android.hardware.camera' ],
        permissions: [ 'android.permission.INTERNET', 'android.permission.CAMERA' ]
      )

      result = described_class.call(app)

      expect(result[:apps].first[:versions].first[:compatibility]).to eq(
        min_sdk: 24, target_sdk: 34,
        abis: [ 'arm64-v8a', 'armeabi-v7a' ], screen_densities: [ 'xhdpi', 'xxhdpi' ],
        required_features: [ 'android.hardware.camera' ],
        permissions: [ 'android.permission.INTERNET', 'android.permission.CAMERA' ]
      )
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

    it 'reads real editorial flags once an admin has set them (Task 31a)' do
      app, = build_app_with_release
      app.update!(featured: true, editors_pick: true)

      result = described_class.call(app)

      expect(result[:apps].first[:editorial]).to eq(featured: true, editors_pick: true)
    end

    it 'includes only current-or-upcoming sponsored slots, soonest first (Task 31a)' do
      app, = build_app_with_release
      upcoming = SponsoredSlot.create!(app: app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
      SponsoredSlot.create!(app: app, starts_at: 10.days.from_now, ends_at: 11.days.from_now)
      SponsoredSlot.create!(app: app, starts_at: 10.days.ago, ends_at: 1.day.ago) # expired, excluded

      result = described_class.call(app)

      expect(result[:apps].first[:sponsored_slots]).to eq(
        [
          { starts_at: upcoming.starts_at.utc.iso8601, ends_at: upcoming.ends_at.utc.iso8601 },
          { starts_at: SponsoredSlot.order(:starts_at).second.starts_at.utc.iso8601,
            ends_at: SponsoredSlot.order(:starts_at).second.ends_at.utc.iso8601 },
        ]
      )
    end

    it "lists an app's collection memberships as slugs (Task 31a)" do
      app, = build_app_with_release
      picks = Collection.create!(slug: 'editors-picks', name: "Editor's Picks")
      new_and_notable = Collection.create!(slug: 'new-and-notable', name: 'New & Notable')
      CollectionApp.create!(app: app, collection: new_and_notable)
      CollectionApp.create!(app: app, collection: picks)

      result = described_class.call(app)

      expect(result[:apps].first[:collections]).to eq(%w[editors-picks new-and-notable])
    end

    it 'publishes the top-level collections registry regardless of which app was serialized (Task 31a)' do
      app, = build_app_with_release
      Collection.create!(slug: 'new-and-notable', name: 'New & Notable', description: 'Fresh releases')
      Collection.create!(slug: 'editors-picks', name: "Editor's Picks")

      result = described_class.call(app)

      expect(result[:collections]).to eq(
        [
          { slug: 'editors-picks', name: "Editor's Picks", description: nil },
          { slug: 'new-and-notable', name: 'New & Notable', description: 'Fresh releases' },
        ]
      )
    end
  end

  describe '.for_live_apps' do
    it 'only includes apps whose listing_status is live' do
      live_app = create(:app, listing_status: :live)
      create(:app, listing_status: :draft)

      result = described_class.for_live_apps

      expect(result[:apps].map { |a| a[:id] }).to eq([ live_app.id ])
    end

    # Task 37b-iii-s3.
    describe 'tenant scoping' do
      let(:generated_at) { Time.utc(2026, 9, 30, 12) }
      let(:acme) { create(:tenant, tenant_id: 'acme') }
      let(:globex) { create(:tenant, tenant_id: 'globex') }

      def live_app(**attrs)
        create(:app, listing_status: :live, listed_at: Time.current, **attrs)
      end

      def ids(result)
        result[:apps].map { |a| a[:id] }
      end

      it 'is byte-identical for the default tenant when no app has a tenant (golden)' do
        live_app
        live_app
        create(:app, listing_status: :draft)

        before_tenants = described_class.call(App.listing_live, generated_at: generated_at)

        [{}, { tenant: nil }, { tenant: 'default' }].each do |args|
          result = described_class.for_live_apps(generated_at: generated_at, **args)
          expect(JSON.generate(result)).to eq(JSON.generate(before_tenants)), "differed for #{args.inspect}"
        end
      end

      it 'keeps every tenant\'s apps out of the default index' do
        default_app = live_app
        live_app(tenant: acme)

        expect(ids(described_class.for_live_apps(generated_at: generated_at))).to eq([ default_app.id ])
      end

      it 'puts a tenant\'s own live apps in its index and nobody else\'s' do
        default_app = live_app
        acme_app = live_app(tenant: acme)
        globex_app = live_app(tenant: globex)
        live_app(tenant: acme, listing_status: :draft)

        acme_ids = ids(described_class.for_live_apps(tenant: acme, generated_at: generated_at))
        globex_ids = ids(described_class.for_live_apps(tenant: 'globex', generated_at: generated_at))

        expect(acme_ids).to eq([ acme_app.id ])
        expect(globex_ids).to eq([ globex_app.id ])
        expect(acme_ids + globex_ids).not_to include(default_app.id)
      end

      it 'omits collections and sponsored slots when editorial is false, and keeps them by default' do
        Collection.create!(slug: 'staff-picks', name: 'Staff picks')
        app = live_app
        SponsoredSlot.create!(app: app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
        app.collections << Collection.find_by!(slug: 'staff-picks')

        with = described_class.call(App.listing_live, generated_at: generated_at)
        without = described_class.call(App.listing_live, generated_at: generated_at, editorial: false)

        expect(with[:collections].map { |c| c[:slug] }).to eq(%w[staff-picks])
        expect(with[:apps].first).to include(collections: %w[staff-picks])
        expect(with[:apps].first[:sponsored_slots]).not_to be_empty
        expect(without[:collections]).to eq([])
        expect(without[:apps].first).to include(collections: [], sponsored_slots: [])
      end

      describe 'collections (s6a)' do
        def member(app, collection) = CollectionApp.create!(app: app, collection: collection)

        it 'leaves the default index byte-identical when a tenant owns collections (golden)' do
          app = live_app
          picks = Collection.create!(slug: 'staff-picks', name: 'Staff picks')
          member(app, picks)
          before = JSON.generate(described_class.for_live_apps(generated_at: generated_at))

          Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)

          expect(JSON.generate(described_class.for_live_apps(generated_at: generated_at))).to eq(before)
        end

        it 'gives a tenant only its own collections, and only those slugs on its apps' do
          Collection.create!(slug: 'staff-picks', name: 'Staff picks')
          acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', description: 'Ours', tenant: acme)
          Collection.create!(slug: 'globex-picks', name: 'Globex picks', tenant: globex)
          acme_app = live_app(tenant: acme)
          member(acme_app, acme_picks)

          result = described_class.for_live_apps(tenant: acme, generated_at: generated_at)

          expect(result[:collections]).to eq([ { slug: 'acme-picks', name: 'Acme picks', description: 'Ours' } ])
          expect(result[:apps].first[:collections]).to eq(%w[acme-picks])
        end

        it 'keeps a slug on an app only when it resolves in the same registry' do
          acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
          acme_app = live_app(tenant: acme)
          member(acme_app, acme_picks)

          # Same apps, the default tenant's view of the registry: the slug must not appear.
          result = described_class.call(App.where(id: acme_app.id), generated_at: generated_at)

          expect(result[:collections]).to eq([])
          expect(result[:apps].first[:collections]).to eq([])
        end

        it 'gives an unknown tenant no collections, never the default registry' do
          Collection.create!(slug: 'staff-picks', name: 'Staff picks')

          result = described_class.for_live_apps(tenant: 'no-such-tenant', generated_at: generated_at)

          expect(result[:collections]).to eq([])
        end

        it 'carries a tenant\'s own apps\' sponsored slots next to its collections (s6b)' do
          acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
          acme_app = live_app(tenant: acme)
          member(acme_app, acme_picks)
          SponsoredSlot.create!(app: acme_app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)

          result = described_class.for_live_apps(tenant: acme, generated_at: generated_at)

          expect(result[:apps].first).to include(collections: %w[acme-picks])
          expect(result[:apps].first[:sponsored_slots].size).to eq(1)
        end

        it 'never puts one tenant\'s slots in another tenant\'s or the default index (s6b)' do
          default_app = live_app
          acme_app = live_app(tenant: acme)
          globex_app = live_app(tenant: globex)
          [ default_app, acme_app, globex_app ].each do |a|
            SponsoredSlot.create!(app: a, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
          end

          [ nil, acme, globex ].each do |t|
            result = described_class.for_live_apps(tenant: t, generated_at: generated_at)

            expect(result[:apps].size).to eq(1)
            expect(result[:apps].first[:sponsored_slots].size).to eq(1)
          end
        end

        it 'leaves the default index byte-identical when a tenant\'s app has slots (golden, s6b)' do
          app = live_app
          SponsoredSlot.create!(app: app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)
          before = JSON.generate(described_class.for_live_apps(generated_at: generated_at))

          SponsoredSlot.create!(app: live_app(tenant: acme), starts_at: 1.day.from_now, ends_at: 2.days.from_now)

          expect(JSON.generate(described_class.for_live_apps(generated_at: generated_at))).to eq(before)
        end

        it 'keeps sponsored slots for the default tenant' do
          app = live_app
          SponsoredSlot.create!(app: app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)

          expect(described_class.for_live_apps(generated_at: generated_at)[:apps].first[:sponsored_slots]).not_to be_empty
        end

        it 'lets editorial: false still switch off everything, whatever the tenant' do
          acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
          acme_app = live_app(tenant: acme)
          member(acme_app, acme_picks)

          result = described_class.call(App.where(id: acme_app.id), generated_at: generated_at, tenant: acme,
                                                                    editorial: false)

          expect(result[:collections]).to eq([])
          expect(result[:apps].first).to include(collections: [], sponsored_slots: [])
        end
      end

      describe 'a parent tenant\'s index (38c)' do
        let!(:child_co) { create(:tenant, tenant_id: 'child-co', parent: acme) }

        it 'lists its own live apps and its descendants\', and never the default tenant\'s or a stranger\'s' do
          default_app = live_app
          acme_app = live_app(tenant: acme)
          child_app = live_app(tenant: child_co)
          globex_app = live_app(tenant: globex)
          live_app(tenant: child_co, listing_status: :draft)

          acme_ids = ids(described_class.for_live_apps(tenant: acme, generated_at: generated_at))

          expect(acme_ids).to contain_exactly(acme_app.id, child_app.id)
          expect(acme_ids).not_to include(default_app.id, globex_app.id)
        end

        it 'keeps the child\'s index to the child\'s own apps' do
          live_app(tenant: acme)
          child_app = live_app(tenant: child_co)

          result = described_class.for_live_apps(tenant: child_co, generated_at: generated_at)

          expect(ids(result)).to eq([ child_app.id ])
        end

        it 'leaves the default index byte-identical when a tenant tree owns apps (golden, 38c)' do
          live_app
          before = JSON.generate(described_class.for_live_apps(generated_at: generated_at))

          live_app(tenant: acme)
          live_app(tenant: child_co)

          expect(JSON.generate(described_class.for_live_apps(generated_at: generated_at))).to eq(before)
        end

        it 'carries a descendant app\'s own slots, but not its collection slugs (registry is per tenant)' do
          child_picks = Collection.create!(slug: 'child-picks', name: 'Child picks', tenant: child_co)
          child_app = live_app(tenant: child_co)
          CollectionApp.create!(app: child_app, collection: child_picks)
          SponsoredSlot.create!(app: child_app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)

          result = described_class.for_live_apps(tenant: acme, generated_at: generated_at)

          expect(result[:collections]).to eq([])
          expect(result[:apps].first).to include(id: child_app.id, collections: [])
          expect(result[:apps].first[:sponsored_slots].size).to eq(1)
        end
      end

      it 'gives an unknown tenant an empty app list, not the default catalog' do
        live_app

        expect(described_class.for_live_apps(tenant: 'no-such-tenant', generated_at: generated_at)[:apps]).to eq([])
      end
    end
  end
end
