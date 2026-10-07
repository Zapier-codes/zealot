# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# Task 32/33 (D-Store leaves 7.a.vii.zi / 7.a.vii.zo): replacing a whole set of listing pictures. Real
# ListingGraphic rows and the real LocalAdapter over a tmpdir, like listing_graphic_ingest_spec.rb. Written
# by imitating that spec; NOT run (the standing operator instruction is no testing).
RSpec.describe ListingGraphicsReplacer do
  def chunk(type, data = ''.b)
    [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack('N')
  end

  def png(width: 1080, height: 1920)
    ihdr = [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + chunk('IDAT', 'x') + chunk('IEND')
  end

  def feature_png
    png(width: 1024, height: 500)
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

  def replace(kind:, uploads:, **options)
    described_class.call(app: app, kind: kind, uploads: uploads, adapter: adapter, **options)
  end

  describe 'screenshots' do
    it 'becomes the whole ordered set, positions 0..n, replacing what was there' do
      replace(kind: 'screenshot', uploads: [write('a.png', png)])
      result = replace(kind: 'screenshot', uploads: [write('b.png', png), write('c.png', png)])

      expect(result).to be_ok
      expect(app.listing_graphics.reload.count).to eq(2)
      expect(app.listing_graphics.ordered.pluck(:position)).to eq([0, 1])
      expect(app.listing_graphics.pluck(:sha256)).to eq(result.graphics.map(&:sha256))
    end

    it 'is idempotent: running the same set twice leaves the same rows' do
      uploads = [write('a.png', png), write('b.png', png)]
      first = replace(kind: 'screenshot', uploads: uploads)
      second = replace(kind: 'screenshot', uploads: uploads)

      expect(second.graphics.map(&:sha256)).to eq(first.graphics.map(&:sha256))
      expect(app.listing_graphics.reload.count).to eq(2)
    end
  end

  describe 'the feature graphic' do
    it 'is replaced in place, never doubled' do
      replace(kind: 'feature_graphic', uploads: [write('f1.png', feature_png)])
      result = replace(kind: 'feature_graphic', uploads: [write('f2.png', feature_png)])

      expect(result).to be_ok
      expect(app.listing_graphics.reload.count).to eq(1)
      expect(app.listing_graphics.first.sha256).to eq(result.graphics.first.sha256)
    end
  end

  describe 'all or nothing' do
    it 'leaves the existing pictures untouched when any upload is refused' do
      replace(kind: 'screenshot', uploads: [write('good.png', png)])
      before = app.listing_graphics.reload.pluck(:id, :sha256)

      result = replace(kind: 'screenshot',
                       uploads: [write('good2.png', png), write('bad.png', png(width: 1080, height: 2400))])

      expect(result).not_to be_ok
      expect(result.violations).to be_present
      expect(app.listing_graphics.reload.pluck(:id, :sha256)).to eq(before)
    end

    it 'refuses an empty set without removing anything' do
      replace(kind: 'screenshot', uploads: [write('good.png', png)])
      result = replace(kind: 'screenshot', uploads: [])

      expect(result).not_to be_ok
      expect(app.listing_graphics.reload.count).to eq(1)
    end

    it 'refuses more than the maximum screenshots without removing anything' do
      replace(kind: 'screenshot', uploads: [write('good.png', png)])
      too_many = Array.new(ListingGraphicRules::MAX_SCREENSHOTS + 1) { |i| write("s#{i}.png", png) }

      result = replace(kind: 'screenshot', uploads: too_many)

      expect(result).not_to be_ok
      expect(app.listing_graphics.reload.count).to eq(1)
    end
  end
end
