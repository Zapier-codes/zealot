# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 43e. Real images made with ImageMagick (the same library the service uses), so the sizes below are
# real. NOT run (the operator said no testing).
RSpec.describe ListingGraphicFit do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def make(name, size, color: 'red', format: nil)
    path = File.join(dir, name)
    MiniMagick.convert do |convert|
      convert.size(size)
      convert << "xc:#{color}"
      convert << "#{format}:#{path}" if format
      convert << path unless format
    end
    path
  end

  def dims(path)
    image = MiniMagick::Image.open(path)
    [ image.width, image.height ]
  end

  it 'crops a 1080 x 2400 phone capture to 2:1 and says so' do
    result = described_class.call(path: make('a.png', '1080x2400'), kind: 'screenshot')

    expect(result).to be_changed
    expect(dims(result.path)).to eq([ 1080, 2160 ])
    expect(result.notes.join).to include('cropped 1080x2400 to 1080x2160')
    result.cleanup
    expect(File).not_to exist(result.path)
  end

  it 'leaves a picture that already fits as the original file' do
    path = make('b.png', '1080x1920')
    result = described_class.call(path: path, kind: 'screenshot')

    expect(result).not_to be_changed
    expect(result.path).to eq(path)
  end

  it 'scales a side over 3840 px down and one under 320 px up' do
    big = described_class.call(path: make('c.png', '4000x6000'), kind: 'screenshot')
    expect(dims(big.path).max).to be <= 3840

    small = described_class.call(path: make('d.png', '200x300'), kind: 'screenshot')
    expect(dims(small.path).min).to be >= 320
  end

  it 'makes a feature graphic exactly 1024 x 500' do
    result = described_class.call(path: make('e.png', '1600x900'), kind: 'feature_graphic')

    expect(dims(result.path)).to eq([ 1024, 500 ])
  end

  it 'returns the original path for a file it cannot read, so the ingest gives the real refusal' do
    path = File.join(dir, 'f.png')
    File.write(path, 'not an image')
    result = described_class.call(path: path, kind: 'screenshot')

    expect(result).not_to be_changed
    expect(result.path).to eq(path)
  end

  it 'does nothing for an unknown kind or a missing file' do
    expect(described_class.call(path: nil, kind: 'screenshot').path).to be_nil
    expect(described_class.call(path: make('g.png', '800x800'), kind: 'banner')).not_to be_changed
  end

  # Task 43f-1 (NOT run). The icon keeps its transparency (D43-5) and is always a 512 x 512 PNG.
  describe "kind: 'icon'" do
    def alpha?(path)
      ListingGraphicInspector.facts_from_file(path).alpha
    end

    it 'scales a 432 x 432 WebP up to a 512 x 512 PNG' do
      result = described_class.call(path: make('i1.webp', '432x432'), kind: 'icon')

      expect(result).to be_changed
      expect(dims(result.path)).to eq([ 512, 512 ])
      expect(ListingGraphicInspector.facts_from_file(result.path).content_type).to eq('image/png')
      result.cleanup
    end

    it 'centre-crops a non-square picture to a square first and says so' do
      result = described_class.call(path: make('i2.png', '600x400'), kind: 'icon')

      expect(dims(result.path)).to eq([ 512, 512 ])
      expect(result.notes.join).to include('cropped 600x400 to 400x400')
      result.cleanup
    end

    it 'keeps transparency' do
      result = described_class.call(path: make('i3.png', '300x300', color: 'none'), kind: 'icon')

      expect(alpha?(result.path)).to be(true)
      result.cleanup
    end

    it 'scales a larger square down to 512 x 512' do
      result = described_class.call(path: make('i4.png', '1024x1024'), kind: 'icon')

      expect(dims(result.path)).to eq([ 512, 512 ])
      result.cleanup
    end

    it 'returns the original for a file it cannot read' do
      path = File.join(dir, 'bad.png')
      File.write(path, 'not an image')
      result = described_class.call(path: path, kind: 'icon')

      expect(result).not_to be_changed
      expect(result.path).to eq(path)
    end
  end
end
