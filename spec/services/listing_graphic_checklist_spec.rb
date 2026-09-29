# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-e. Pure Ruby (plain structs, no database); run in the sandbox that wrote it with a shim in
# place of rails_helper.
RSpec.describe ListingGraphicChecklist do
  Graphic = Struct.new(:kind, :width, :height, :alt_text, :storage_key, :sha256)

  def shot(width: 1080, height: 1920, alt: 'Home', stored: true)
    Graphic.new('screenshot', width, height, alt, (stored ? 'k' : nil), (stored ? 'h' : nil))
  end

  def feature(alt: 'Cover', stored: true)
    Graphic.new('feature_graphic', 1024, 500, alt, (stored ? 'k' : nil), (stored ? 'h' : nil))
  end

  def item(items, key)
    items.find { |entry| entry.key == key }
  end

  let(:video_id) { 'dQw4w9WgXcQ' }

  it 'lists the five items in the order the panel shows them' do
    expect(described_class.call([]).map(&:key))
      .to eq(%i[min_screenshots promo_screenshots feature_graphic alt_text video])
  end

  it 'has nothing ticked for an app with no graphics and no video' do
    items = described_class.call([])

    expect(items.map(&:met)).to all(be(false))
    expect(described_class.met_count(items)).to eq(0)
  end

  describe 'min_screenshots' do
    it 'ticks at two stored screenshots and not at one' do
      expect(item(described_class.call([ shot ]), :min_screenshots).met).to be(false)
      expect(item(described_class.call([ shot, shot ]), :min_screenshots).met).to be(true)
    end

    it 'reports how many are counted against the target' do
      entry = item(described_class.call([ shot ]), :min_screenshots)

      expect([ entry.count, entry.target ]).to eq([ 1, 2 ])
    end

    it 'ignores the feature graphic and a row whose bytes are not stored yet' do
      items = described_class.call([ shot, shot(stored: false), feature ])

      expect(item(items, :min_screenshots).count).to eq(1)
      expect(item(items, :min_screenshots).met).to be(false)
    end
  end

  describe 'promo_screenshots' do
    it 'ticks at four portrait 1080 x 1920 screenshots' do
      entry = item(described_class.call(Array.new(4) { shot }), :promo_screenshots)

      expect(entry.met).to be(true)
      expect([ entry.count, entry.target ]).to eq([ 4, 4 ])
    end

    it 'does not tick at three, and counts what qualifies' do
      entry = item(described_class.call(Array.new(3) { shot }), :promo_screenshots)

      expect(entry.met).to be(false)
      expect(entry.count).to eq(3)
    end

    it 'accepts landscape 1920 x 1080 and a larger 9:16 size' do
      graphics = [ shot(width: 1920, height: 1080), shot(width: 1440, height: 2560),
                   shot(width: 1080, height: 1920), shot(width: 2160, height: 3840) ]

      expect(item(described_class.call(graphics), :promo_screenshots).met).to be(true)
    end

    it 'does not count a screenshot under 1080 px on its short side' do
      expect(item(described_class.call([ shot(width: 720, height: 1280) ]), :promo_screenshots).count).to eq(0)
    end

    it 'does not count a 20:9 phone capture even though it is large enough' do
      expect(item(described_class.call([ shot(width: 1080, height: 2400) ]), :promo_screenshots).count).to eq(0)
    end

    it 'does not count a square or a 4:3 screenshot' do
      graphics = [ shot(width: 2000, height: 2000), shot(width: 2048, height: 1536) ]

      expect(item(described_class.call(graphics), :promo_screenshots).count).to eq(0)
    end

    it 'tolerates a rounded export within one percent of 9:16' do
      expect(described_class.promo_ready?(1081, 1920)).to be(true)
      expect(described_class.promo_ready?(1079, 1920)).to be(false) # under the 1080 px minimum
      expect(described_class.promo_ready?(1080, 1940)).to be(false)
    end

    it 'does not count a row whose bytes are not stored yet' do
      expect(item(described_class.call([ shot(stored: false) ]), :promo_screenshots).count).to eq(0)
    end

    it 'refuses missing or non-integer sizes without raising' do
      expect(described_class.promo_ready?(nil, 1920)).to be(false)
      expect(described_class.promo_ready?(1080, 0)).to be(false)
      expect(described_class.promo_ready?('1080', '1920')).to be(false)
    end
  end

  describe 'feature_graphic' do
    it 'ticks once a stored feature graphic exists' do
      expect(item(described_class.call([ feature ]), :feature_graphic).met).to be(true)
    end

    it 'does not tick for a screenshot alone or an unstored feature graphic' do
      expect(item(described_class.call([ shot ]), :feature_graphic).met).to be(false)
      expect(item(described_class.call([ feature(stored: false) ]), :feature_graphic).met).to be(false)
    end
  end

  describe 'alt_text' do
    it 'ticks when every stored graphic has a description' do
      expect(item(described_class.call([ shot, feature ]), :alt_text).met).to be(true)
    end

    it 'does not tick when one is missing, blank or only spaces' do
      expect(item(described_class.call([ shot, shot(alt: nil) ]), :alt_text).met).to be(false)
      expect(item(described_class.call([ shot, shot(alt: '') ]), :alt_text).met).to be(false)
      expect(item(described_class.call([ shot, shot(alt: '   ') ]), :alt_text).met).to be(false)
    end

    it 'does not tick for an empty listing (nothing is described because nothing exists)' do
      expect(item(described_class.call([]), :alt_text).met).to be(false)
    end

    it 'ignores a row that is not stored yet' do
      expect(item(described_class.call([ shot, shot(alt: nil, stored: false) ]), :alt_text).met).to be(true)
    end
  end

  describe 'video' do
    it 'ticks for a plain 11-character ID' do
      expect(item(described_class.call([], video_youtube_id: video_id), :video).met).to be(true)
    end

    it 'does not tick for nil, blank, a URL or a playlist ID' do
      [ nil, '', 'https://youtu.be/dQw4w9WgXcQ', 'PLrAXtmErZgOeiKm4sgNOknGvNjby9efdf' ].each do |value|
        expect(item(described_class.call([], video_youtube_id: value), :video).met).to be(false)
      end
    end
  end

  it 'never reads the database or changes what it is given' do
    graphics = [ shot, feature ].freeze

    expect { described_class.call(graphics, video_youtube_id: video_id) }.not_to raise_error
    expect(graphics.size).to eq(2)
  end

  it 'counts how many items are met' do
    items = described_class.call(Array.new(4) { shot } + [ feature ], video_youtube_id: video_id)

    expect(described_class.met_count(items)).to eq(5)
  end
end
