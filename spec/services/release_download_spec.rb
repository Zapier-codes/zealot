# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

RSpec.describe ReleaseDownload do
  let(:release_class) do
    Struct.new(:id, :file, :patched_file_path, :file_storage_key, :patched_file_storage_key, keyword_init: true)
  end
  let(:tmp) { Dir.mktmpdir }
  let(:primary) { File.join(tmp, 'app.apk').tap { |path| File.write(path, 'original') } }
  let(:patched) { File.join(tmp, 'app_internal_proxy.apk').tap { |path| File.write(path, 'patched') } }
  let(:storage) { instance_double(ReleaseStorage) }
  let(:release) do
    release_class.new(id: 7, file: double(path: primary), patched_file_path: nil,
                            file_storage_key: 'uploads/apps/a1/r7/binary/app.apk')
  end

  subject(:download) { described_class.new(release, storage: storage) }

  after { FileUtils.remove_entry(tmp) }

  describe 'when the file is still on local disk' do
    it 'serves the primary file without touching storage' do
      expect(storage).not_to receive(:url_for)

      expect(download.resolve).to have_attributes(kind: :file, path: primary)
    end

    it 'prefers the patched internal APK over the primary file' do
      release.patched_file_path = patched

      expect(download.resolve).to have_attributes(kind: :file, path: patched)
    end

    it 'falls back to the primary file when the patched one is gone' do
      release.patched_file_path = File.join(tmp, 'gone.apk')

      expect(download.resolve).to have_attributes(kind: :file, path: primary)
    end
  end

  describe 'after a redeploy wiped the disk' do
    before { FileUtils.rm_f(primary) }

    it 'redirects to the signed storage URL' do
      allow(storage).to receive(:url_for).with('uploads/apps/a1/r7/binary/app.apk').and_return('https://cdn.test/signed')

      expect(download.resolve).to have_attributes(kind: :redirect, url: 'https://cdn.test/signed')
    end

    it 'prefers the mirrored patched APK when the release has one' do
      release.patched_file_path = File.join(tmp, 'gone.apk')
      release.patched_file_storage_key = 'uploads/apps/a1/r7/binary/app_internal_proxy.apk'
      allow(storage).to receive(:url_for).with('uploads/apps/a1/r7/binary/app_internal_proxy.apk')
                                         .and_return('https://cdn.test/patched')

      expect(download.resolve).to have_attributes(kind: :redirect, url: 'https://cdn.test/patched')
    end

    it 'uses the primary key when a patched release never got its patched copy mirrored' do
      release.patched_file_path = File.join(tmp, 'gone.apk')
      allow(storage).to receive(:url_for).with('uploads/apps/a1/r7/binary/app.apk').and_return('https://cdn.test/primary')

      expect(download.resolve).to have_attributes(kind: :redirect, url: 'https://cdn.test/primary')
    end

    it 'is missing when the release was never mirrored' do
      release.file_storage_key = nil

      expect(download.resolve.kind).to eq(:missing)
    end

    it 'is missing when storage has no such file' do
      allow(storage).to receive(:url_for).and_return(nil)

      expect(download.resolve.kind).to eq(:missing)
    end

    it 'is missing, not a 500, when storage is unreachable or misconfigured' do
      allow(storage).to receive(:url_for).and_raise(ReleaseStorage::StorageError, 'GitHub down')
      expect(download.resolve.kind).to eq(:missing)

      allow(storage).to receive(:url_for).and_raise(ReleaseStorage::ConfigurationError, 'no token')
      expect(download.resolve.kind).to eq(:missing)
    end
  end

  describe '#available?' do
    it 'is true for a local file or a mirrored key, and never calls storage' do
      expect(storage).not_to receive(:url_for)

      expect(download.available?).to be(true)
      FileUtils.rm_f(primary)
      expect(download.available?).to be(true)
      release.file_storage_key = nil
      expect(download.available?).to be(false)
    end
  end
end
