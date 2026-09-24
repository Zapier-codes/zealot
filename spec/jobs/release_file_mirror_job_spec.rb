# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'digest'

RSpec.describe ReleaseFileMirrorJob do
  let(:release_class) do
    Struct.new(:id, :file, :patched_file_path, :file_storage_key, :patched_file_storage_key, :file_sha256,
               keyword_init: true) do
      def [](column)
        public_send(column)
      end

      def update_columns(attributes)
        attributes.each { |column, value| public_send("#{column}=", value) }
      end
    end
  end
  let(:tmp) { Dir.mktmpdir }
  let(:primary) { File.join(tmp, 'app.aab').tap { |path| File.write(path, 'clean-aab') } }
  let(:patched) { File.join(tmp, 'app_internal_proxy.apk').tap { |path| File.write(path, 'patched') } }
  let(:release) { release_class.new(id: 7, file: double(path: primary)) }
  let(:storage) { instance_double(ReleaseStorage) }

  before do
    stub_const('Release', class_double('Release', find_by: release))
    allow(ReleaseStorage).to receive(:remote?).and_return(true)
    allow(ReleaseStorage).to receive(:new).with(release).and_return(storage)
    allow(storage).to receive(:store_binary) { |path| "uploads/apps/a1/r7/binary/#{File.basename(path)}" }
  end

  after { FileUtils.remove_entry(tmp) }

  it 'mirrors the primary file and records its key' do
    described_class.new.perform(7)

    expect(storage).to have_received(:store_binary).with(primary).once
    expect(release.file_storage_key).to eq('uploads/apps/a1/r7/binary/app.aab')
    expect(release.patched_file_storage_key).to be_nil
  end

  it "records the primary file's sha256" do
    described_class.new.perform(7)

    expect(release.file_sha256).to eq(Digest::SHA256.hexdigest('clean-aab'))
  end

  it 'does not re-hash a release that already has a stored sha256' do
    release.file_sha256 = 'already-there'

    described_class.new.perform(7)

    expect(release.file_sha256).to eq('already-there')
  end

  it 'still hashes the primary file even when nothing needs mirroring (local adapter)' do
    allow(ReleaseStorage).to receive(:remote?).and_return(false)

    described_class.new.perform(7)

    expect(release.file_sha256).to eq(Digest::SHA256.hexdigest('clean-aab'))
    expect(storage).not_to have_received(:store_binary)
  end

  it 'also mirrors the patched internal APK of a Play-targeted release' do
    release.patched_file_path = patched

    described_class.new.perform(7)

    expect(release.file_storage_key).to eq('uploads/apps/a1/r7/binary/app.aab')
    expect(release.patched_file_storage_key).to eq('uploads/apps/a1/r7/binary/app_internal_proxy.apk')
  end

  it 'does not upload a file that is already mirrored' do
    release.file_storage_key = 'uploads/apps/a1/r7/binary/app.aab'

    described_class.new.perform(7)

    expect(storage).not_to have_received(:store_binary)
  end

  it 'skips a file that is no longer on disk' do
    FileUtils.rm_f(primary)

    described_class.new.perform(7)

    expect(storage).not_to have_received(:store_binary)
    expect(release.file_storage_key).to be_nil
    expect(release.file_sha256).to be_nil
  end

  it 'does nothing on the local adapter' do
    allow(ReleaseStorage).to receive(:remote?).and_return(false)

    described_class.new.perform(7)

    expect(storage).not_to have_received(:store_binary)
  end

  it 'ignores a release that no longer exists' do
    allow(Release).to receive(:find_by).and_return(nil)

    expect { described_class.new.perform(404) }.not_to raise_error
  end

  it 'keeps going to the patched file when the primary upload fails, and never raises' do
    release.patched_file_path = patched
    allow(storage).to receive(:store_binary).with(primary).and_raise(ReleaseStorage::StorageError, 'boom')
    allow(storage).to receive(:store_binary).with(patched).and_return('uploads/apps/a1/r7/binary/patched.apk')

    expect { described_class.new.perform(7) }.not_to raise_error

    expect(release.file_storage_key).to be_nil
    expect(release.patched_file_storage_key).to eq('uploads/apps/a1/r7/binary/patched.apk')
  end

  it 'logs a configuration problem instead of failing the job' do
    allow(ReleaseStorage).to receive(:remote?).and_raise(ReleaseStorage::ConfigurationError, 'adapter unset')

    expect { described_class.new.perform(7) }.not_to raise_error
  end

  describe '.backfill' do
    it 'enqueues every release that has no stored copy yet' do
      relation = double('relation')
      allow(relation).to receive(:find_each).and_yield(double(id: 1)).and_yield(double(id: 2))
      allow(Release).to receive(:where).with(file_storage_key: nil).and_return(relation)
      allow(described_class).to receive(:perform_later)

      described_class.backfill

      expect(described_class).to have_received(:perform_later).with(1)
      expect(described_class).to have_received(:perform_later).with(2)
    end
  end
end
