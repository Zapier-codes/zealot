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

        it 'still omits sponsored slots for a tenant (s6b), while carrying its collections' do
          acme_picks = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
          acme_app = live_app(tenant: acme)
          member(acme_app, acme_picks)
          SponsoredSlot.create!(app: acme_app, starts_at: 1.day.from_now, ends_at: 2.days.from_now)

          result = described_class.for_live_apps(tenant: acme, generated_at: generated_at)

          expect(result[:apps].first).to include(collections: %w[acme-picks], sponsored_slots: [])
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

      it 'gives an unknown tenant an empty app list, not the default catalog' do
        live_app

        expect(described_class.for_live_apps(tenant: 'no-such-tenant', generated_at: generated_at)[:apps]).to eq([])
      end
    end
  end
end
