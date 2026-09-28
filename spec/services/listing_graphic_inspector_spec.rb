# frozen_string_literal: true

require 'rails_helper'
require 'stringio'
require 'tempfile'
require 'zlib'

# Task 27d-d2-a: pure logic, no Rails needed. Every fixture is built in memory (no binary files are
# committed): a PNG from its chunks, a JPEG from its marker segments. The session that wrote this
# also ran the real inspector against real ImageMagick output (see the session entry in handover.md).
RSpec.describe ListingGraphicInspector do
  def chunk(type, data = ''.b)
    [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack('N')
  end

  # A PNG made of IHDR, `extra` chunks (before IDAT, as the format requires), one IDAT and IEND.
  # The pixel data is a placeholder: the inspector never decodes it.
  def png(width: 1080, height: 1920, color_type: 2, extra: [])
    ihdr = [width, height, 8, color_type, 0, 0, 0].pack('NNCCCCC')
    described_class::PNG_SIGNATURE + chunk('IHDR', ihdr) + extra.join + chunk('IDAT', 'x') + chunk('IEND')
  end

  # A JPEG with an APP0 segment (so the walk has something to skip), then a frame of the given size.
  def jpeg(width: 1080, height: 1920, marker: 0xC0)
    app0 = [0xFF, 0xE0, 0x00, 0x10].pack('C*') + 'JFIF'.b + ("\x00".b * 10)
    sof = [0xFF, marker, 0x00, 0x0B, 8, height, width, 1, 1, 0x11, 0].pack('CCCCCnnCCCC')
    "\xFF\xD8".b + app0 + sof
  end

  def facts_for(bytes)
    described_class.facts(StringIO.new(bytes.b))
  end

  describe '.facts' do
    it 'reads an opaque RGB PNG: type, size and no alpha' do
      facts = facts_for(png)
      expect([facts.content_type, facts.width, facts.height, facts.alpha]).to eq(['image/png', 1080, 1920, false])
    end

    it 'reports the byte size of the whole file' do
      bytes = png
      expect(facts_for(bytes).byte_size).to eq(bytes.bytesize)
    end

    it 'reports alpha for RGB + alpha (colour type 6) and grey + alpha (colour type 4)' do
      expect(facts_for(png(color_type: 6)).alpha).to be(true)
      expect(facts_for(png(color_type: 4)).alpha).to be(true)
    end

    it 'reports alpha for an indexed PNG that has a tRNS chunk, and none without one' do
      plte = chunk('PLTE', "\x00\x00\x00".b)
      expect(facts_for(png(color_type: 3, extra: [plte])).alpha).to be(false)
      expect(facts_for(png(color_type: 3, extra: [plte, chunk('tRNS', "\x00".b)])).alpha).to be(true)
    end

    it 'reports alpha for an RGB PNG that has a tRNS chunk (one transparent colour)' do
      expect(facts_for(png(color_type: 2, extra: [chunk('tRNS', "\x00\x00\x00\x00\x00\x00".b)])).alpha).to be(true)
    end

    it 'calls an animated PNG (acTL before IDAT) image/apng, which the rules refuse' do
      actl = chunk('acTL', [2, 0].pack('NN'))
      facts = facts_for(png(extra: [actl]))
      expect(facts.content_type).to eq('image/apng')
      expect(ListingGraphicRules::ALLOWED_CONTENT_TYPES).not_to include(facts.content_type)
    end

    it 'leaves alpha unknown (nil) for a PNG that ends before IDAT, so the rules refuse it' do
      truncated = png(color_type: 2).byteslice(0, 8 + 8 + 13 + 4)
      facts = facts_for(truncated)
      expect([facts.content_type, facts.width, facts.height, facts.alpha]).to eq(['image/png', 1080, 1920, nil])
    end

    it 'leaves the size unknown for a PNG cut off inside IHDR' do
      facts = facts_for(png.byteslice(0, 8 + 8 + 5))
      expect([facts.content_type, facts.width, facts.height]).to eq(['image/png', nil, nil])
    end

    it 'reads a baseline JPEG: type, size and no alpha' do
      facts = facts_for(jpeg)
      expect([facts.content_type, facts.width, facts.height, facts.alpha]).to eq(['image/jpeg', 1080, 1920, false])
    end

    it 'reads a progressive JPEG (SOF2)' do
      facts = facts_for(jpeg(marker: 0xC2, width: 720, height: 1280))
      expect([facts.width, facts.height]).to eq([720, 1280])
    end

    it 'leaves the size unknown for a JPEG with no frame header' do
      facts = facts_for(described_class::JPEG_SIGNATURE + [0xE0, 0x00, 0x04, 0, 0].pack('C*'))
      expect([facts.content_type, facts.width, facts.height]).to eq(['image/jpeg', nil, nil])
    end

    it 'names a GIF as image/gif whatever the file is called' do
      gif = 'GIF89a'.b + [500, 500].pack('vv') + ("\x00".b * 20)
      facts = facts_for(gif)
      expect([facts.content_type, facts.width, facts.height]).to eq(['image/gif', 500, 500])
    end

    it 'names WebP as image/webp' do
      webp = 'RIFF'.b + [100].pack('V') + 'WEBP'.b + ("\x00".b * 20)
      expect(facts_for(webp).content_type).to eq('image/webp')
    end

    it 'returns no type for bytes that are not an image, and for an empty file' do
      expect(facts_for('<html>not an image</html>').content_type).to be_nil
      expect(facts_for('').content_type).to be_nil
      expect(facts_for('').byte_size).to eq(0)
    end

    it 'does not trust a name: a GIF stored as shot.png is still a GIF' do
      Tempfile.create(['shot', '.png']) do |file|
        file.binmode
        file.write('GIF89a'.b + [500, 500].pack('vv') + ("\x00".b * 20))
        file.flush
        expect(described_class.facts_from_file(file.path).content_type).to eq('image/gif')
      end
    end
  end

  describe 'with ListingGraphicRules' do
    def violations_for(bytes, kind: 'screenshot')
      facts = facts_for(bytes)
      ListingGraphicRules.file_violations(kind: kind, content_type: facts.content_type, byte_size: facts.byte_size,
                                          width: facts.width, height: facts.height, alpha: facts.alpha).map(&:code)
    end

    it 'accepts a 1080 x 1920 opaque PNG and a 1080 x 1920 JPEG' do
      expect(violations_for(png)).to be_empty
      expect(violations_for(jpeg)).to be_empty
    end

    it 'accepts a 1024 x 500 opaque PNG as a feature graphic' do
      expect(violations_for(png(width: 1024, height: 500), kind: 'feature_graphic')).to be_empty
    end

    it 'refuses a GIF, WebP, an alpha PNG, an animated PNG and a non-image' do
      expect(violations_for('GIF89a'.b + [1080, 1920].pack('vv') + ("\x00".b * 20))).to include(:type_not_allowed)
      expect(violations_for('RIFF'.b + [100].pack('V') + 'WEBP'.b + ("\x00".b * 20))).to include(:type_not_allowed)
      expect(violations_for(png(color_type: 6))).to include(:alpha_channel)
      expect(violations_for(png(extra: [chunk('acTL', [2, 0].pack('NN'))]))).to include(:type_not_allowed)
      expect(violations_for('not an image')).to include(:type_not_allowed)
    end

    it 'refuses a PNG whose transparency could not be established' do
      expect(violations_for(png.byteslice(0, 8 + 8 + 13 + 4))).to include(:alpha_unknown)
    end
  end
end
