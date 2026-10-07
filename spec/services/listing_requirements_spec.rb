# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 43b-1 (NOT run; the operator said no testing). Plain structs stand in for the app, its releases and graphics.
RSpec.describe ListingRequirements do
  Rel = Struct.new(:icon_storage_key, :icon, keyword_init: true)
  Gfx = Struct.new(:kind, :storage_key, :sha256, keyword_init: true)
  FakeApp = Struct.new(:listed_at, :catalog_releases, :listing_graphics, keyword_init: true)

  def shot(stored: true)
    Gfx.new(kind: 'screenshot', storage_key: stored ? 'k' : nil, sha256: stored ? 'h' : nil)
  end

  let(:with_icon) { Rel.new(icon_storage_key: 'uploads/icon.png') }
  let(:no_icon) { Rel.new }

  def app(releases: [ with_icon ], graphics: [ shot, shot ], listed_at: nil)
    FakeApp.new(listed_at: listed_at, catalog_releases: releases, listing_graphics: graphics)
  end

  it 'is empty for an app with an icon and 2 stored screenshots' do
    expect(described_class.call(app)).to eq([])
  end

  it 'lists the icon and the screenshots with their count for an app with 1 screenshot and no icon' do
    missing = described_class.call(app(releases: [ no_icon ], graphics: [ shot ]))

    expect(missing.map(&:key)).to eq(%i[icon screenshots])
    expect(missing.last.count).to eq(1)
    expect(missing.last.target).to eq(2)
    expect(described_class.sentence(missing)).to eq('no icon; 1 of 2 screenshots')
  end

  it 'counts only stored screenshots, not the feature graphic or a row still waiting for its bytes' do
    graphics = [ shot, shot(stored: false), Gfx.new(kind: 'feature_graphic', storage_key: 'k', sha256: 'h') ]

    expect(described_class.call(app(graphics: graphics)).map(&:key)).to eq(%i[screenshots])
  end

  it 'counts an icon still on disk as an icon, and none when the app has no catalog release' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'icon.png').tap { |file| File.write(file, 'x') }
      on_disk = Rel.new(icon: Struct.new(:path).new(path))

      expect(described_class.call(app(releases: [ on_disk ]))).to eq([])
    end
    expect(described_class.call(app(releases: [])).map(&:key)).to eq(%i[icon])
  end

  it 'exempts an app that has already been listed' do
    expect(described_class.call(app(releases: [], graphics: [], listed_at: Time.current))).to eq([])
  end
end
