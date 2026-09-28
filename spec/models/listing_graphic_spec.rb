# frozen_string_literal: true

require 'rails_helper'

# Task 27d-d1: ListingGraphic is a data-only model this slice (no uploader, route or reader).
# Needs Postgres for the uniqueness/slot examples. NOT run in the sandbox that wrote it (no Rails
# boot or database there); ListingGraphicRules itself, which this model re-checks on save, was run
# for real -- see spec/services/listing_graphic_rules_spec.rb and the session entry in
# handover.md.
RSpec.describe ListingGraphic do
  let(:app) { create(:app) }

  def build_screenshot(overrides = {})
    described_class.new({ app: app, kind: 'screenshot', device: 'phone', content_type: 'image/png',
                          byte_size: 500_000, width: 1080, height: 1920 }.merge(overrides))
  end

  it 'is valid with acceptable, in-policy attributes' do
    expect(build_screenshot).to be_valid
  end

  it 'refuses an unknown kind at the enum layer' do
    expect { build_screenshot.kind = 'banner' }.to raise_error(ArgumentError)
  end

  it 'refuses an unknown device at the enum layer' do
    expect { build_screenshot.device = 'tablet' }.to raise_error(ArgumentError)
  end

  it 'refuses a screenshot whose pixel size breaks the Play rules' do
    graphic = build_screenshot(width: 100, height: 100)
    expect(graphic).not_to be_valid
    expect(graphic.errors[:base] + graphic.errors[:width]).not_to be_empty
  end

  it 'refuses a feature graphic that is not exactly 1024 x 500' do
    graphic = build_screenshot(kind: 'feature_graphic', content_type: 'image/jpeg', width: 1024, height: 400)
    expect(graphic).not_to be_valid
    expect(graphic.errors[:base].join).to match(/1024 x 500/)
  end

  it 'refuses alt text over 140 characters' do
    graphic = build_screenshot(alt_text: 'x' * 141)
    expect(graphic).not_to be_valid
    expect(graphic.errors[:alt_text]).not_to be_empty
  end

  it 'refuses a ninth screenshot on the same app and device' do
    8.times { |n| build_screenshot(position: n).save!(validate: false) }
    ninth = build_screenshot(position: 8)
    expect(ninth).not_to be_valid
    expect(ninth.errors[:base].join).to match(/at most 8 screenshots/)
  end

  it 'allows a ninth screenshot on a different app' do
    8.times { |n| build_screenshot(position: n).save!(validate: false) }
    other_app_screenshot = build_screenshot(app: create(:app))
    expect(other_app_screenshot).to be_valid
  end

  it 'allows only one feature graphic per app and device at the database layer' do
    build_screenshot(kind: 'feature_graphic', content_type: 'image/jpeg', width: 1024, height: 500)
      .save!(validate: false)
    duplicate = build_screenshot(kind: 'feature_graphic', content_type: 'image/jpeg', width: 1024, height: 500)

    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it 'destroys its graphics when the owning app is destroyed' do
    graphic = build_screenshot
    graphic.save!(validate: false)

    expect { app.destroy! }.to change(described_class, :count).by(-1)
  end

  describe 'stored-bytes cleanup (27d-d2-b)' do
    include ActiveJob::TestHelper

    it 'enqueues one cleanup with the stored key when a graphic is destroyed' do
      graphic = build_screenshot(storage_key: 'uploads/apps/1/graphics/g1/graphic.png')
      graphic.save!(validate: false)

      expect { graphic.destroy! }
        .to have_enqueued_job(ListingGraphicStorageCleanupJob)
        .with(graphic.id, ['uploads/apps/1/graphics/g1/graphic.png']).exactly(:once)
    end

    it 'enqueues nothing for a graphic that was never stored' do
      graphic = build_screenshot
      graphic.save!(validate: false)

      expect { graphic.destroy! }.not_to have_enqueued_job(ListingGraphicStorageCleanupJob)
    end

    it 'enqueues a cleanup for each stored graphic when the owning app is destroyed' do
      build_screenshot(position: 0, storage_key: 'k0').save!(validate: false)
      build_screenshot(position: 1, storage_key: 'k1').save!(validate: false)

      expect { app.destroy! }.to have_enqueued_job(ListingGraphicStorageCleanupJob).exactly(:twice)
    end
  end
end
