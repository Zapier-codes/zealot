# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'
require 'digest'

# Task 27d-d2-c. Real ListingGraphic rows and the real LocalAdapter over a tmpdir, so bytes really are
# stored. Images are built in memory (no binary fixtures), like listing_graphic_inspector_spec.rb.
# NOT run under Rails in the sandbox that wrote it (no Rails boot or Postgres there); the same service was
# run against real ActiveRecord and SQLite (see the session entry in handover.md).
RSpec.describe ListingGraphicIngest do
  def chunk(type, data = ''.b)
    [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack('N')
  end

  def png(width: 1080, height: 1920, color_type: 2, extra: [])
    ihdr = [width, height, 8, color_type, 0, 0, 0].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + extra.join + chunk('IDAT', 'x') + chunk('IEND')
  end

  def jpeg(width: 1024, height: 500)
    sof = [0xFF, 0xC0, 0x00, 0x0B, 8, height, width, 1, 1, 0x11, 0].pack('CCCCCnnCCCC')
    "\xFF\xD8".b + sof
  end

  def write(name, bytes)
    File.join(dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  let(:dir) { Dir.mktmpdir }
  let(:root) { Dir.mktmpdir }
  let(:adapter) { ReleaseStorage::LocalAdapter.new(root: root) }
  let(:app) { create(:app) }

  after do
    FileUtils.remove_entry(dir)
    FileUtils.remove_entry(root)
  end

  def ingest(path, kind: 'screenshot', **options)
    described_class.call(app: app, path: path, kind: kind, adapter: adapter, **options)
  end

  def stored_files
    Dir[File.join(root, '**', '*')].select { |path| File.file?(path) }
  end

  describe 'a good screenshot' do
    it 'becomes a row with the facts, hash and key from the bytes, and the bytes are stored' do
      bytes = png
      result = ingest(write('upload.bin', bytes), alt_text: 'Home screen')
      graphic = result.graphic.reload

      expect(result).to be_ok
      expect(graphic).to have_attributes(kind: 'screenshot', device: 'phone', position: 0, alt_text: 'Home screen',
                                         content_type: 'image/png', width: 1080, height: 1920,
                                         byte_size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes),
                                         storage_key: "uploads/apps/a#{app.id}/graphics/g#{graphic.id}/graphic.png")
      expect(File.binread(File.join(root, graphic.storage_key))).to eq(bytes)
    end

    it 'takes the next free position and never reuses a deleted one' do
      first = ingest(write('a.bin', png)).graphic
      second = ingest(write('b.bin', png)).graphic
      third = ingest(write('c.bin', png)).graphic
      second.destroy!

      expect([first.position, second.position, third.position]).to eq([0, 1, 2])
      expect(ingest(write('d.bin', png)).graphic.position).to eq(3)
    end

    it 'names a JPEG graphic.jpg whatever the upload was called' do
      graphic = ingest(write('shot.png', jpeg(width: 1080, height: 1920))).graphic

      expect(graphic.content_type).to eq('image/jpeg')
      expect(graphic.storage_key).to end_with('graphic.jpg')
    end

    it 'does not touch the uploaded file' do
      path = write('upload.bin', png)

      expect { ingest(path) }.not_to(change { [File.exist?(path), File.binread(path)] })
    end
  end

  describe 'a refusal' do
    {
      'a GIF renamed .png' => "GIF89a\x01\x00\x01\x00\x00\x00\x00;".b,
      'a WebP' => "RIFF\x00\x00\x00\x00WEBPVP8 ".b,
      'plain text' => 'not an image'.b,
      'an empty file' => ''.b,
      'an animated PNG' => nil,
      'a PNG with alpha' => nil
    }.each do |label, bytes|
      it "writes nothing for #{label}" do
        bytes ||= label.include?('animated') ? png(extra: [chunk('acTL', "\x00".b * 8)]) : png(color_type: 6)
        result = ingest(write('upload.png', bytes))

        expect(result).not_to be_ok
        expect(result.graphic).to be_nil
        expect(result.violations).not_to be_empty
        expect(ListingGraphic.count).to eq(0)
        expect(stored_files).to be_empty
      end
    end

    it 'names the alpha channel' do
      expect(ingest(write('a.png', png(color_type: 6))).violations.map(&:code)).to eq([:alpha_channel])
    end

    it 'refuses a missing or nil path' do
      expect(ingest(File.join(dir, 'none.png')).violations.map(&:code)).to eq([:file_missing])
      expect(ingest(nil).violations.map(&:code)).to eq([:file_missing])
    end

    it 'refuses long alt text, an unknown kind and an unknown device' do
      path = write('a.bin', png)

      expect(ingest(path, alt_text: 'x' * 141).violations.map(&:code)).to eq([:alt_text_too_long])
      expect(ingest(path, kind: 'banner').violations.map(&:code)).to include(:kind_unknown)
      expect(ingest(path, device: 'tablet').violations.map(&:code)).to eq([:device_unknown])
    end

    it 'refuses a ninth screenshot and writes nothing for it' do
      path = write('a.bin', png)
      8.times { ingest(path) }

      result = nil
      expect { result = ingest(path) }.not_to(change { [ListingGraphic.count, stored_files.size] })
      expect(result.violations.map(&:code)).to eq([:screenshot_slots_full])
    end

    it 'does not count another app’s screenshots against the cap' do
      path = write('a.bin', png)
      8.times { ingest(path) }

      other = described_class.call(app: create(:app), path: path, kind: 'screenshot', adapter: adapter)
      expect(other).to be_ok
    end
  end

  describe 'a feature graphic' do
    it 'is accepted at exactly 1024 x 500 and takes position 0' do
      result = ingest(write('f.jpg', jpeg), kind: 'feature_graphic')

      expect(result).to be_ok
      expect(result.graphic).to have_attributes(kind: 'feature_graphic', position: 0)
    end

    it 'is refused at any other size' do
      expect(ingest(write('f.jpg', jpeg(height: 501)), kind: 'feature_graphic').violations.map(&:code))
        .to eq([:feature_graphic_size])
    end

    it 'replaces the app’s existing one and enqueues deletion of the old bytes' do
      old = ingest(write('f1.jpg', jpeg), kind: 'feature_graphic').graphic
      result = nil

      expect { result = ingest(write('f2.jpg', jpeg), kind: 'feature_graphic') }
        .to have_enqueued_job(ListingGraphicStorageCleanupJob).with(old.id, [old.storage_key])
      expect(result).to be_ok
      expect(app.listing_graphics.where(kind: 'feature_graphic').pluck(:id)).to eq([result.graphic.id])
    end

    it 'keeps the old one when the replacement is refused' do
      old = ingest(write('f1.jpg', jpeg), kind: 'feature_graphic').graphic

      ingest(write('f2.jpg', jpeg(height: 400)), kind: 'feature_graphic')

      expect(app.listing_graphics.where(kind: 'feature_graphic').pluck(:id)).to eq([old.id])
    end
  end

  describe 'a storage failure' do
    let(:failing_adapter) do
      Class.new do
        def put(*, **)
          raise ReleaseStorage::StorageError, 'boom'
        end

        def delete(*)
          true
        end
      end.new
    end

    it 'raises StorageFailed and leaves no row' do
      expect { described_class.call(app: app, path: write('a.bin', png), kind: 'screenshot', adapter: failing_adapter) }
        .to raise_error(described_class::StorageFailed, /boom/)
      expect(ListingGraphic.count).to eq(0)
    end

    it 'keeps the old feature graphic and enqueues no cleanup when a replacement cannot be stored' do
      old = ingest(write('f1.jpg', jpeg), kind: 'feature_graphic').graphic

      expect do
        expect do
          described_class.call(app: app, path: write('f2.jpg', jpeg), kind: 'feature_graphic',
                               adapter: failing_adapter)
        end.to raise_error(described_class::StorageFailed)
      end.not_to have_enqueued_job(ListingGraphicStorageCleanupJob)
      expect(app.listing_graphics.pluck(:id)).to eq([old.id])
    end

    it 'removes bytes it already stored when a later step fails' do
      allow_any_instance_of(ListingGraphic).to receive(:update_columns).and_raise('db down')
      allow(adapter).to receive(:delete).and_call_original

      expect { ingest(write('a.bin', png)) }.to raise_error('db down')
      expect(adapter).to have_received(:delete).once
      expect(stored_files).to be_empty
      expect(ListingGraphic.count).to eq(0)
    end
  end
end
