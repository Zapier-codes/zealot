# frozen_string_literal: true

require 'rails_helper'

# Task 27d-d1: pure logic, no Rails needed. Run for real in the sandbox that wrote it (see the
# session entry in handover.md) with `ruby -r./app/services/listing_graphic_rules.rb` -- every
# example below reproduces one of those checks under RSpec.
RSpec.describe ListingGraphicRules do
  def screenshot(overrides = {})
    { kind: 'screenshot', content_type: 'image/png', byte_size: 500_000, width: 1080, height: 1920,
      alpha: false }.merge(overrides)
  end

  describe '.violations' do
    it 'accepts a 1080 x 1920 PNG screenshot' do
      expect(described_class.violations(**screenshot)).to be_empty
    end

    it 'refuses a GIF' do
      violations = described_class.violations(**screenshot(content_type: 'image/gif'))
      expect(violations.map(&:code)).to include(:type_not_allowed)
    end

    it 'refuses WebP' do
      violations = described_class.violations(**screenshot(content_type: 'image/webp'))
      expect(violations.map(&:code)).to include(:type_not_allowed)
    end

    it 'refuses a PNG with an alpha channel' do
      violations = described_class.violations(**screenshot(alpha: true))
      expect(violations.map(&:code)).to include(:alpha_channel)
    end

    it 'refuses transparency that was never checked' do
      violations = described_class.violations(**screenshot(alpha: nil))
      expect(violations.map(&:code)).to include(:alpha_unknown)
    end

    it 'refuses a side under 320 px' do
      violations = described_class.violations(**screenshot(width: 300, height: 900))
      expect(violations.map(&:code)).to include(:side_too_small)
    end

    it 'refuses a side over 3840 px' do
      violations = described_class.violations(**screenshot(width: 4000, height: 1920))
      expect(violations.map(&:code)).to include(:side_too_large)
    end

    it 'refuses a long side over twice the short side' do
      violations = described_class.violations(**screenshot(width: 500, height: 1100))
      expect(violations.map(&:code)).to include(:aspect_too_wide)
    end

    it 'refuses a file over 8 MB' do
      violations = described_class.violations(**screenshot(byte_size: 9 * 1024 * 1024))
      expect(violations.map(&:code)).to include(:file_too_large)
    end

    it 'refuses alt text over 140 characters' do
      violations = described_class.violations(**screenshot(alt_text: 'x' * 141))
      expect(violations.map(&:code)).to include(:alt_text_too_long)
    end

    it 'accepts alt text at exactly 140 characters' do
      violations = described_class.violations(**screenshot(alt_text: 'x' * 140))
      expect(violations).to be_empty
    end

    it 'refuses an unknown kind' do
      violations = described_class.violations(**screenshot(kind: 'banner'))
      expect(violations.map(&:code)).to include(:kind_unknown)
    end

    it 'accepts a 1024 x 500 feature graphic' do
      violations = described_class.violations(**screenshot(kind: 'feature_graphic', content_type: 'image/jpeg',
                                                            width: 1024, height: 500))
      expect(violations).to be_empty
    end

    it 'refuses a feature graphic of any other size' do
      violations = described_class.violations(**screenshot(kind: 'feature_graphic', content_type: 'image/jpeg',
                                                            width: 1024, height: 501))
      expect(violations.map(&:code)).to include(:feature_graphic_size)
    end
  end

  describe '.screenshot_slot_free?' do
    it 'is free below the cap and full at it' do
      expect(described_class.screenshot_slot_free?(7)).to eq(true)
      expect(described_class.screenshot_slot_free?(8)).to eq(false)
    end
  end

  describe '.youtube_id?' do
    it 'accepts a plain 11-character video id' do
      expect(described_class.youtube_id?('dQw4w9WgXcQ')).to eq(true)
    end

    it 'refuses a full URL, a playlist id and nil' do
      expect(described_class.youtube_id?('https://youtube.com/watch?v=dQw4w9WgXcQ')).to eq(false)
      expect(described_class.youtube_id?('PLxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx')).to eq(false)
      expect(described_class.youtube_id?(nil)).to eq(false)
    end
  end
end
