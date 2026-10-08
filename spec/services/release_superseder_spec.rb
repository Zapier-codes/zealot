# frozen_string_literal: true

require 'rails_helper'

# Task 46c: a newer release replaces the older ones of its channel. Written by imitating the other release
# service specs; NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe ReleaseSuperseder do
  let!(:app) { create(:app, name: 'Superseder App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }

  def make_release(version, **attrs)
    Release.new({ channel: channel, version: version, changelog: [], release_version: "1.0.#{version}",
                  build_version: version.to_s }.merge(attrs)).tap { |r| r.save!(validate: false) }
  end

  # A CI-built release that can be installed: compile done and the universal APK fully recorded.
  def make_installable(version, **attrs)
    make_release(version, ci_compile_state: 'done', universal_apk_storage_key: "a1/r#{version}/app.apk",
                          universal_apk_sha256: 'a' * 64, universal_apk_size: 1234, **attrs)
  end

  before do
    allow(ReleaseStorageCleanupJob).to receive(:perform_later)
    allow(CatalogIndexPublishJob).to receive(:enqueue_for)
  end

  describe '#call' do
    it 'removes the older releases of the channel and keeps the named one' do
      old_one = make_release(1)
      old_two = make_release(2)
      keeper = make_installable(3)

      result = described_class.new(keeper).call

      expect(result.removed.map(&:id)).to eq([old_one.id, old_two.id])
      expect(result.failed).to eq([])
      expect(Release.where(id: [old_one.id, old_two.id])).to be_empty
      expect(Release.exists?(keeper.id)).to be(true)
    end

    it 'never touches a release uploaded after the named one' do
      older = make_release(1)
      keeper = make_installable(2)
      newer = make_release(3)

      described_class.new(keeper).call

      expect(Release.exists?(older.id)).to be(false)
      expect(Release.exists?(newer.id)).to be(true)
    end

    it 'never touches another channel' do
      other_channel = app.schemes.first.channels.create!(name: 'Other', device_type: :android)
      elsewhere = Release.new(channel: other_channel, version: 1, changelog: [], release_version: '0.9.0',
                              build_version: '1').tap { |r| r.save!(validate: false) }
      keeper = make_installable(2)

      described_class.new(keeper).call

      expect(Release.exists?(elsewhere.id)).to be(true)
    end

    it 'lists what would go and removes nothing on a dry run' do
      old_one = make_release(1)
      keeper = make_installable(2)

      result = described_class.new(keeper).call(dry_run: true)

      expect(result.dry_run).to be(true)
      expect(result.removed.map(&:id)).to eq([old_one.id])
      expect(Release.exists?(old_one.id)).to be(true)
      expect(CatalogIndexPublishJob).not_to have_received(:enqueue_for)
    end

    it 'cleans the stored files of every removed release, the universal APK included' do
      make_installable(1)
      keeper = make_installable(2)
      described_class.new(keeper).call

      expect(ReleaseStorageCleanupJob).to have_received(:perform_later)
        .with(anything, array_including('a1/r1/app.apk'))
    end

    it 'republishes the index of a live app after a real removal' do
      allow_any_instance_of(App).to receive(:listing_live?).and_return(true)
      make_release(1)
      keeper = make_installable(2)

      described_class.new(keeper).call

      expect(CatalogIndexPublishJob).to have_received(:enqueue_for).at_least(:once)
    end

    it 'does not republish when nothing was older' do
      allow_any_instance_of(App).to receive(:listing_live?).and_return(true)
      keeper = make_installable(1)

      result = described_class.new(keeper).call

      expect(result.removed).to eq([])
      expect(CatalogIndexPublishJob).not_to have_received(:enqueue_for)
    end

    it 'reports a release that could not be removed and carries on with the others' do
      stuck = make_release(1)
      free = make_release(2)
      keeper = make_installable(3)
      allow_any_instance_of(Release).to receive(:destroy).and_wrap_original do |original, *args|
        original.receiver.id == stuck.id ? false : original.call(*args)
      end

      result = described_class.new(keeper).call

      expect(result.failed.map(&:id)).to eq([stuck.id])
      expect(result.removed.map(&:id)).to eq([free.id])
      expect(Release.exists?(stuck.id)).to be(true)
    end

    it 'refuses while the named release is not available, and removes nothing' do
      old_one = make_release(1)
      keeper = make_installable(2, status: 'held')

      expect { described_class.new(keeper).call }.to raise_error(described_class::Refused, 'not_available')
      expect(Release.exists?(old_one.id)).to be(true)
    end

    it 'refuses while CI has not finished the named release, and removes nothing' do
      old_one = make_release(1)
      keeper = make_release(2, ci_compile_state: 'dispatched')

      expect { described_class.new(keeper).call }.to raise_error(described_class::Refused, 'not_installable')
      expect(Release.exists?(old_one.id)).to be(true)
    end

    it 'refuses a CI release whose universal APK is only half recorded' do
      make_release(1)
      keeper = make_release(2, ci_compile_state: 'done', universal_apk_storage_key: 'a1/r2/app.apk')

      expect { described_class.new(keeper).call }.to raise_error(described_class::Refused, 'not_installable')
    end

    it 'accepts a release with no CI step that has its file' do
      make_release(1)
      keeper = make_release(2, file_storage_key: 'uploads/apps/a1/r2/binary/app.apk')

      result = described_class.new(keeper).call

      expect(result.removed.size).to eq(1)
    end

    it 'refuses an archived app' do
      make_release(1)
      keeper = make_installable(2)
      app.update!(archived: true)

      expect { described_class.new(keeper).call }.to raise_error(described_class::Refused, 'app_archived')
    end
  end
end
