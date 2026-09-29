# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 27d-d2-d. The real ReleaseStorage::LocalAdapter over a tmpdir and the real ListingGraphicStorage,
# so bytes are really read back; only the graphic is a Struct (the service needs its id, app_id, content
# type and storage key, not a database row).
RSpec.describe ListingGraphicDownload do
  let(:graphic_class) { Struct.new(:id, :app_id, :content_type, :storage_key, keyword_init: true) }
  let(:root) { Dir.mktmpdir }
  let(:adapter) { ReleaseStorage::LocalAdapter.new(root: root) }
  let(:key) { 'uploads/apps/a1/graphics/g7/graphic.png' }
  let(:graphic) { graphic_class.new(id: 7, app_id: 1, content_type: 'image/png', storage_key: key) }
  let(:storage) { ListingGraphicStorage.new(graphic, adapter: adapter) }

  subject(:download) { described_class.new(graphic, storage: storage) }

  before do
    FileUtils.mkdir_p(File.join(root, File.dirname(key)))
    File.binwrite(File.join(root, key), 'png-bytes')
  end

  after { FileUtils.remove_entry(root) }

  describe 'on the local adapter (no URL)' do
    it 'reads the stored bytes back' do
      source = download.resolve

      expect(source).to have_attributes(kind: :data, data: 'png-bytes', content_type: 'image/png')
      expect(download).to be_available
    end

    it 'leaves no temporary file behind' do
      expect { download.resolve }.not_to(change { Dir[File.join(Dir.tmpdir, 'graphic-7-*')].size })
    end

    it 'is missing when storage no longer has the object' do
      FileUtils.rm_f(File.join(root, key))

      expect(download.resolve.kind).to eq(:missing)
    end
  end

  describe 'on an adapter that signs URLs' do
    it 'redirects, and never reads the bytes' do
      allow(adapter).to receive(:url_for).with(key, expires_in: 3600).and_return('https://cdn.test/graphic')
      expect(adapter).not_to receive(:get)

      expect(download.resolve).to have_attributes(kind: :redirect, url: 'https://cdn.test/graphic')
    end
  end

  describe 'a graphic that cannot be served' do
    it 'is missing when it was never ingested (no key)' do
      graphic.storage_key = nil

      expect(download.resolve.kind).to eq(:missing)
      expect(download).not_to be_available
    end

    it 'is missing for a content type Play does not accept' do
      graphic.content_type = 'image/gif'

      expect(download.resolve.kind).to eq(:missing)
      expect(download).not_to be_available
    end

    it 'is missing, not an error, when storage is unreachable or misconfigured' do
      allow(adapter).to receive(:url_for).and_raise(ReleaseStorage::StorageError, 'boom')
      expect(download.resolve.kind).to eq(:missing)

      allow(adapter).to receive(:url_for).and_raise(ReleaseStorage::ConfigurationError, 'no adapter')
      expect(download.resolve.kind).to eq(:missing)
    end
  end
end
