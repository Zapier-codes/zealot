# frozen_string_literal: true

require 'rails_helper'

# Task 40e: a release CI has compiled is served and advertised as its signed universal APK.
# Needs Postgres. Releases are built like release_catalog_index_publish_spec.rb builds them (no Release
# factory exists; `save!(validate: false)` skips the create-only `file` presence validation).
# Written, NOT run (the operator said no testing): look here first if CI is red for this slice.
RSpec.describe Release, 'universal APK (Task 40e)' do
  let(:sha) { 'c' * 64 }
  let!(:app) { App.create!(name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
           .tap { |r| r.save!(validate: false) }
  end

  def compiled!(**overrides)
    release.update_columns({ ci_compile_state: 'done',
                             universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/universal.apk',
                             universal_apk_sha256: sha, universal_apk_size: 4321 }.merge(overrides))
    release.reload
  end

  describe '#serves_universal_apk?' do
    it 'is false for a release never sent to CI' do
      expect(release.serves_universal_apk?).to be(false)
    end

    it 'is false while the compile is queued, dispatched or failed, even with the columns filled' do
      %w[queued dispatched failed].each do |state|
        compiled!(ci_compile_state: state)
        expect(release.serves_universal_apk?).to be(false), "expected false for #{state}"
      end
    end

    it 'is true only when done with the key, the hash and a positive size recorded' do
      compiled!
      expect(release.serves_universal_apk?).to be(true)
    end

    it 'is false when any recorded value is missing' do
      [{ universal_apk_storage_key: nil }, { universal_apk_sha256: nil }, { universal_apk_size: nil },
       { universal_apk_size: 0 }].each do |missing|
        compiled!(**missing)
        expect(release.serves_universal_apk?).to be(false), "expected false for #{missing}"
      end
    end
  end

  describe 'what a compiled release reports' do
    before { compiled! }

    it 'has a file, is named .apk and reports the APK size' do
      expect(release.file?).to be(true)
      expect(release.file_extname).to eq('.apk')
      expect(release.size).to eq(4321)
      expect(release.download_filename).to end_with('.apk')
    end

    # Task 44c: the app's name and the version, nothing else.
    it 'names the download <app slug>-<version>.apk, with no build number and no time' do
      expect(release.download_filename).to eq('live-app-1.0.1.apk')
    end

    it 'names the download from the release, not from an uploader identifier that is not there' do
      channel.update_columns(download_filename_type: 'original_filename')

      expect(release.reload.download_filename).to eq(release.send(:default_filename))
      expect(release.download_filename).to end_with('.apk')
    end

    # Task 41d: with the channel set to the original file name, a download is called what it was stored as.
    describe 'a channel that offers the original file name (Task 41d)' do
      before { channel.update_columns(download_filename_type: 'original_filename') }

      it 'offers the stored name of a compiled release' do
        compiled!(universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/Storeapp-1.0.1-1.apk')

        expect(release.download_filename).to eq('Storeapp-1.0.1-1.apk')
      end

      it 'offers the stored name of a release held only in storage' do
        release.update_columns(file_storage_key: 'uploads/apps/a1/r1/binary/Storeapp-1.0.1-1.apk')

        expect(release.reload.download_filename).to eq('Storeapp-1.0.1-1.apk')
      end

      it 'does not offer an old generic name' do
        release.update_columns(file_storage_key: 'uploads/apps/a1/r1/binary/universal.apk')

        expect(release.reload.download_filename).to eq(release.send(:default_filename))
      end

      it 'leaves the other filename type alone' do
        channel.update_columns(download_filename_type: 'version_datetime')
        compiled!(universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/Storeapp-1.0.1-1.apk')

        expect(release.download_filename).to eq(release.send(:name_version_filename))
      end
    end
  end

  describe '#file?' do
    it 'is false with no local file and nothing stored' do
      expect(release.file?).to be(false)
    end

    it 'is true when only a stored copy exists (a redeploy wiped the disk)' do
      release.update_columns(file_storage_key: 'uploads/apps/a1/r1/binary/app.apk')

      expect(release.reload.file?).to be(true)
      expect(release.file_extname).to eq('.apk')
    end
  end

  describe 'the catalog index' do
    it 'republishes when CI records its result' do
      release
      release.update_columns(ci_compile_state: 'dispatched')

      expect do
        release.reload.update!(ci_compile_state: 'done', ci_compile_finished_at: Time.current,
                               universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/universal.apk',
                               universal_apk_sha256: sha, universal_apk_size: 4321)
      end.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'does not republish for a change that does not touch the advertised file' do
      release

      expect { release.reload.update!(ci_compile_error: 'x') }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end
  end
end
