# frozen_string_literal: true

require 'rails_helper'

# Task 40f: the local `.aab` is deleted only after the four checks. Needs Postgres. The release is built like
# release_ci_compile_hook_spec.rb builds one (a real uploaded file with a real extension, saved with
# `validate: false`); storage is stubbed, so no GitHub call is made. Written, NOT run (the operator said no
# testing): look here first if CI is red for this slice.
RSpec.describe ReleaseLocalEvictionJob do
  let(:app) { create(:app, name: 'Eviction app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:extension) { '.aab' }
  let(:storage) { instance_double(ReleaseStorage, exist?: true) }
  let(:remote) { true }
  let!(:release) do
    record = Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
    Tempfile.create(['release', extension]) do |tmp|
      tmp.write('bytes')
      tmp.flush
      record.file = File.open(tmp.path)
      record.save!(validate: false)
    end
    record.update_columns(release_columns.call(record))
    record
  end
  let(:release_columns) do
    lambda do |record|
      {
        ci_compile_state: 'done', universal_apk_storage_key: 'uploads/apps/a1/r1/pipeline/universal.apk',
        universal_apk_sha256: 'a' * 64, universal_apk_size: 1234, file_sha256: 'b' * 64,
        file_storage_key: "uploads/apps/a1/r1/binary/#{File.basename(record.file.path)}"
      }
    end
  end
  let(:local_path) { release.file.path }

  before do
    allow(ReleaseStorage).to receive(:remote?).and_return(remote)
    allow(ReleaseStorage).to receive(:new).and_return(storage)
  end

  after { FileUtils.rm_rf(File.dirname(local_path)) }

  describe '#perform' do
    it 'deletes the local bundle when every check holds, and leaves the row alone' do
      expect(File.file?(local_path)).to be(true)

      expect(described_class.new.perform(release.id)).to eq(:evicted)

      expect(File.exist?(local_path)).to be(false)
      expect(storage).to have_received(:exist?).with(release.file_storage_key)
      release.reload
      expect(release.file_storage_key).to be_present
      expect(release.file_sha256).to eq('b' * 64)
      expect(release.ci_compile_state).to eq('done')
    end

    it 'does nothing, and makes no storage call, when the bundle is already off the disk' do
      File.delete(local_path)

      expect(described_class.new.perform(release.id)).to eq(:nothing_to_evict)
      expect(ReleaseStorage).not_to have_received(:new)
    end

    it 'does nothing for a release that no longer exists' do
      expect(described_class.new.perform(0)).to be_nil
    end

    context 'when storage is the local adapter' do
      let(:remote) { false }

      it 'keeps the file: it is the stored copy' do
        expect(described_class.new.perform(release.id)).to eq(:storage_is_local)
        expect(File.file?(local_path)).to be(true)
      end
    end

    %w[queued dispatched failed].each do |state|
      it "keeps the file while the compile is #{state}" do
        release.update_columns(ci_compile_state: state)

        expect(described_class.new.perform(release.id)).to eq(:compile_not_done)
        expect(File.file?(local_path)).to be(true)
      end
    end

    it 'keeps the file when a done result is only half recorded' do
      release.update_columns(universal_apk_sha256: nil)

      expect(described_class.new.perform(release.id)).to eq(:compile_not_done)
      expect(File.file?(local_path)).to be(true)
    end

    it 'keeps the file when the bundle SHA-256 was never recorded' do
      release.update_columns(file_sha256: nil)

      expect(described_class.new.perform(release.id)).to eq(:sha256_not_recorded)
      expect(File.file?(local_path)).to be(true)
    end

    it 'keeps the file, without asking storage, when it was never mirrored' do
      release.update_columns(file_storage_key: nil)

      expect(described_class.new.perform(release.id)).to eq(:bundle_not_in_storage)
      expect(File.file?(local_path)).to be(true)
      expect(storage).not_to have_received(:exist?)
    end

    it 'keeps the file when the stored key names a different file' do
      release.update_columns(file_storage_key: 'uploads/apps/a1/r1/binary/other.aab')

      expect(described_class.new.perform(release.id)).to eq(:bundle_not_in_storage)
      expect(File.file?(local_path)).to be(true)
    end

    it 'keeps the file when storage does not hold the bundle' do
      allow(storage).to receive(:exist?).and_return(false)

      expect(described_class.new.perform(release.id)).to eq(:bundle_not_in_storage)
      expect(File.file?(local_path)).to be(true)
    end

    it 'keeps the file, and does not raise, when the storage check fails' do
      allow(storage).to receive(:exist?).and_raise(ReleaseStorage::StorageError, 'GitHub is down')

      expect(described_class.new.perform(release.id)).to eq(:storage_unavailable)
      expect(File.file?(local_path)).to be(true)
    end

    it 'keeps the file, and does not raise, when the adapter is misconfigured' do
      allow(ReleaseStorage).to receive(:remote?).and_raise(ReleaseStorage::ConfigurationError, 'not set')

      expect(described_class.new.perform(release.id)).to eq(:storage_unavailable)
      expect(File.file?(local_path)).to be(true)
    end

    context 'when the upload is an APK' do
      let(:extension) { '.apk' }

      it 'never touches it: only the bundle is evicted' do
        expect(described_class.new.perform(release.id)).to eq(:nothing_to_evict)
        expect(File.file?(local_path)).to be(true)
      end
    end
  end

  describe '.backfill' do
    it 'enqueues one job for every release whose compile is done, and no other' do
      other = Release.new(channel: channel, version: 2, changelog: [], release_version: '1.0.2', build_version: '2')
      other.save!(validate: false)
      other.update_columns(ci_compile_state: 'dispatched')

      expect { described_class.backfill }.to have_enqueued_job(described_class).with(release.id).exactly(:once)
      expect { described_class.backfill }.not_to have_enqueued_job(described_class).with(other.id)
    end
  end
end
