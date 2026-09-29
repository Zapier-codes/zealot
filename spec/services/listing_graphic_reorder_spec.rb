# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-c2. The `.moved` examples are pure Ruby and were run in the sandbox that wrote this file
# (with a shim in place of rails_helper). The `.call` examples need Postgres and were NOT run there.
RSpec.describe ListingGraphicReorder do
  describe '.moved' do
    it 'moves an id one place earlier' do
      expect(described_class.moved([ 1, 2, 3 ], 3, 'up')).to eq([ 1, 3, 2 ])
    end

    it 'moves an id one place later' do
      expect(described_class.moved([ 1, 2, 3 ], 1, 'down')).to eq([ 2, 1, 3 ])
    end

    it 'leaves the list alone at either end' do
      expect(described_class.moved([ 1, 2, 3 ], 1, 'up')).to eq([ 1, 2, 3 ])
      expect(described_class.moved([ 1, 2, 3 ], 3, 'down')).to eq([ 1, 2, 3 ])
    end

    it 'leaves the list alone for an unknown direction or an id that is not in it' do
      expect(described_class.moved([ 1, 2, 3 ], 2, 'sideways')).to eq([ 1, 2, 3 ])
      expect(described_class.moved([ 1, 2, 3 ], 2, nil)).to eq([ 1, 2, 3 ])
      expect(described_class.moved([ 1, 2, 3 ], 9, 'up')).to eq([ 1, 2, 3 ])
    end

    it 'never changes its input' do
      ids = [ 1, 2, 3 ].freeze

      expect { described_class.moved(ids, 2, 'up') }.not_to raise_error
      expect(ids).to eq([ 1, 2, 3 ])
    end

    it 'handles a single item and an empty list' do
      expect(described_class.moved([ 1 ], 1, 'up')).to eq([ 1 ])
      expect(described_class.moved([], 1, 'down')).to eq([])
    end
  end

  describe '.call' do
    let!(:app) { create(:app, name: 'Ordered app') }

    def screenshot(position, sha: nil)
      ListingGraphic.create!(app: app, kind: 'screenshot', device: 'phone', position: position,
                             content_type: 'image/png', byte_size: 100, width: 1080, height: 1920,
                             sha256: sha, storage_key: sha && "graphics/#{sha}.png")
    end

    def order
      app.listing_graphics.where(kind: 'screenshot').order(:position).pluck(:id)
    end

    it 'swaps two neighbours without ever putting two rows on one position' do
      a = screenshot(0)
      b = screenshot(1)
      c = screenshot(2)

      result = described_class.call(app: app, graphic: c, direction: 'up')

      expect(result).to be_changed
      expect(order).to eq([ a.id, c.id, b.id ])
      expect(app.listing_graphics.order(:position).pluck(:position)).to eq([ 0, 1, 2 ])
    end

    it 'closes a gap left by a removal when it moves something' do
      a = screenshot(0)
      b = screenshot(3)
      c = screenshot(7)

      described_class.call(app: app, graphic: c, direction: 'up')

      expect(order).to eq([ a.id, c.id, b.id ])
      expect(app.listing_graphics.order(:position).pluck(:position)).to eq([ 0, 1, 2 ])
    end

    it 'writes nothing and publishes nothing when the screenshot cannot move' do
      a = screenshot(0)
      screenshot(1)
      allow(app).to receive(:listing_live?).and_return(true)

      expect(CatalogIndexPublishJob).not_to receive(:enqueue_for)
      result = described_class.call(app: app, graphic: a, direction: 'up')

      expect(result).not_to be_changed
      expect(a.reload.position).to eq(0)
    end

    it 'enqueues exactly one publish for a live app, however many rows moved' do
      screenshot(0)
      screenshot(1)
      c = screenshot(2)
      allow(app).to receive(:listing_live?).and_return(true)

      expect(CatalogIndexPublishJob).to receive(:enqueue_for).once
      described_class.call(app: app, graphic: c, direction: 'up')
    end

    it 'publishes nothing for an app that is not live' do
      screenshot(0)
      b = screenshot(1)
      allow(app).to receive(:listing_live?).and_return(false)

      expect(CatalogIndexPublishJob).not_to receive(:enqueue_for)
      described_class.call(app: app, graphic: b, direction: 'up')
    end

    it "does not touch another app's screenshots or this app's feature graphic" do
      other = create(:app, name: 'Other')
      foreign = ListingGraphic.new(app: other, kind: 'screenshot', device: 'phone', position: 1,
                                   content_type: 'image/png', byte_size: 9, width: 1080, height: 1920)
                              .tap { |record| record.save!(validate: false) }
      feature = ListingGraphic.new(app: app, kind: 'feature_graphic', device: 'phone', position: 0,
                                   content_type: 'image/png', byte_size: 9, width: 1024, height: 500)
                              .tap { |record| record.save!(validate: false) }
      screenshot(0)
      b = screenshot(1)

      described_class.call(app: app, graphic: b, direction: 'up')

      expect(foreign.reload.position).to eq(1)
      expect(feature.reload.position).to eq(0)
    end
  end
end
