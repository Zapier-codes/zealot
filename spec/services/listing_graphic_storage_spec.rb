# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 27d-d2-b: the real ReleaseStorage::LocalAdapter over a tmpdir, so bytes really are written,
# read back and deleted. Only the graphic itself is a Struct (the service needs its id, app_id and
# content_type, not a database row).
RSpec.describe ListingGraphicStorage do
  # Not a constant: a top-level Struct defined inside an example group would leak into every other spec.
  def graphic_with(id, app_id, content_type)
    Struct.new(:id, :app_id, :content_type).new(id, app_id, content_type)
  end

  let(:root) { Dir.mktmpdir }
  let(:adapter) { ReleaseStorage::LocalAdapter.new(root: root) }
  let(:graphic) { graphic_with(7, 12, 'image/png') }
  let(:storage) { described_class.new(graphic, adapter: adapter) }
  let(:source) { File.join(root, 'incoming.bin').tap { |path| File.binwrite(path, 'png-bytes') } }

  after { FileUtils.remove_entry(root) }

  describe '#store' do
    it 'stores under the app-owned graphics key and returns it' do
      expect(storage.store(source)).to eq('uploads/apps/a12/graphics/g7/graphic.png')
      expect(File.binread(File.join(root, 'uploads/apps/a12/graphics/g7/graphic.png'))).to eq('png-bytes')
    end

    it 'names a JPEG graphic.jpg' do
      jpeg = described_class.new(graphic_with(8, 12, 'image/jpeg'), adapter: adapter)

      expect(jpeg.store(source)).to eq('uploads/apps/a12/graphics/g8/graphic.jpg')
    end

    it 'never takes the stored name from the uploaded file name' do
      hostile = File.join(root, '..%2f..%2fevil name.png').tap { |path| File.binwrite(path, 'x') }

      expect(storage.store(hostile)).to eq('uploads/apps/a12/graphics/g7/graphic.png')
    end

    it 'passes the content type to the adapter' do
      fake = instance_double(ReleaseStorage::LocalAdapter, put: nil)

      described_class.new(graphic, adapter: fake).store(source)

      expect(fake).to have_received(:put)
        .with('uploads/apps/a12/graphics/g7/graphic.png', source, content_type: 'image/png')
    end

    it 'refuses a content type Play does not accept, before touching storage' do
      gif = described_class.new(graphic_with(9, 12, 'image/gif'), adapter: adapter)

      expect { gif.store(source) }.to raise_error(ArgumentError, /no storage extension/)
      expect(Dir.glob(File.join(root, 'uploads/**/*'))).to be_empty
    end

    it 'replaces the bytes when stored again under the same graphic' do
      storage.store(source)
      File.binwrite(source, 'new-bytes')
      key = storage.store(source)

      expect(File.binread(File.join(root, key))).to eq('new-bytes')
    end
  end

  describe 'reading and deleting' do
    let!(:key) { storage.store(source) }

    it 'fetches the same bytes back to a local path' do
      dest = File.join(root, 'out', 'fetched.png')

      expect(storage.fetch(key, to: dest)).to eq(dest)
      expect(File.binread(dest)).to eq('png-bytes')
    end

    it 'returns nil from fetch when the key does not exist' do
      expect(storage.fetch('uploads/apps/a12/graphics/g99/graphic.png', to: File.join(root, 'nope'))).to be_nil
    end

    it 'has no direct URL on the local adapter, so the caller serves the file itself' do
      expect(storage.url_for(key)).to be_nil
    end

    it 'reports whether the key exists, and deletes it' do
      expect(storage.exist?(key)).to be(true)

      storage.delete(key)

      expect(storage.exist?(key)).to be(false)
    end
  end

  describe '.new' do
    it 'refuses a graphic that has not been saved, because the key needs its id' do
      expect { described_class.new(graphic_with(nil, 12, 'image/png'), adapter: adapter) }
        .to raise_error(ArgumentError, /must be saved/)
    end
  end
end
