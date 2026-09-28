# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 27d-b. NOT run in the sandbox that wrote it (no Rails boot or database there).
RSpec.describe ReleaseIconDownload do
  let(:release_class) { Struct.new(:id, :icon, :icon_storage_key, keyword_init: true) }
  let(:tmp) { Dir.mktmpdir }
  let(:icon_path) { File.join(tmp, 'icon.png').tap { |path| File.write(path, 'png-bytes') } }
  let(:storage) { instance_double(ReleaseStorage) }
  let(:release) do
    release_class.new(id: 7, icon: double(path: icon_path), icon_storage_key: 'uploads/apps/a1/r7/icons/icon.png')
  end

  subject(:download) { described_class.new(release, storage: storage) }

  after { FileUtils.remove_entry(tmp) }

  describe 'when the icon is still on local disk' do
    it 'serves it without touching storage' do
      expect(storage).not_to receive(:url_for)

      expect(download.resolve).to have_attributes(kind: :file, path: icon_path)
      expect(download).to be_available
    end
  end

  describe 'after a redeploy wiped the disk' do
    before { FileUtils.rm_f(icon_path) }

    it 'redirects to the signed storage URL of the mirrored icon' do
      allow(storage).to receive(:url_for).with('uploads/apps/a1/r7/icons/icon.png').and_return('https://cdn.test/icon')

      expect(download.resolve).to have_attributes(kind: :redirect, url: 'https://cdn.test/icon')
    end

    it 'is missing when the icon was never mirrored' do
      release.icon_storage_key = nil

      expect(download.resolve.kind).to eq(:missing)
      expect(download).not_to be_available
    end

    it 'is missing when storage has no such object' do
      allow(storage).to receive(:url_for).and_return(nil)

      expect(download.resolve.kind).to eq(:missing)
    end

    it 'is missing, not an error, when storage is unreachable or misconfigured' do
      allow(storage).to receive(:url_for).and_raise(ReleaseStorage::StorageError, 'boom')

      expect(download.resolve.kind).to eq(:missing)
    end
  end

  describe 'a release with no icon at all' do
    let(:release) { release_class.new(id: 8, icon: double(path: nil), icon_storage_key: nil) }

    it 'is missing' do
      expect(download.resolve.kind).to eq(:missing)
      expect(download).not_to be_available
    end
  end
end
