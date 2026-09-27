# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ListingEditService do
  describe '#draft' do
    it 'creates an empty draft the first time and reuses it after' do
      app = create(:app)
      service = described_class.new(app: app)

      first = service.draft
      expect(first).to be_persisted
      expect(first).to be_status_draft

      expect(service.draft).to eq(first) # memoized, no second row created
      expect(app.listing_edits.count).to eq(1)
    end

    it 'reuses an existing draft created outside this service instance' do
      app = create(:app)
      existing = create(:listing_edit, app: app, staged_attributes: { 'name' => 'Already staged' })

      expect(described_class.new(app: app).draft).to eq(existing)
    end
  end

  describe '#stage' do
    it 'merges attributes into the draft without touching the live App' do
      app = create(:app, name: 'Live name')
      service = described_class.new(app: app)

      service.stage(name: 'Staged name', category: 'tools')

      expect(app.reload.name).to eq('Live name')
      expect(service.draft.staged_attributes).to eq('name' => 'Staged name', 'category' => 'tools')
    end

    it 'accumulates across multiple calls rather than replacing the whole hash' do
      service = described_class.new(app: create(:app))

      service.stage(name: 'First')
      service.stage(category: 'tools')

      expect(service.draft.staged_attributes).to eq('name' => 'First', 'category' => 'tools')
    end

    it 'silently drops a key that is not a listing field' do
      service = described_class.new(app: create(:app))

      service.stage(name: 'Kept', listing_status: 'live')

      expect(service.draft.staged_attributes).to eq('name' => 'Kept')
    end

    it 'records the editor on the draft it creates' do
      user = create(:user)
      service = described_class.new(app: create(:app), editor: user)

      service.stage(name: 'X')

      expect(service.draft.editor).to eq(user)
    end
  end

  describe '#commit! and #discard!' do
    it 'commits the current draft, applying it to the App' do
      app = create(:app, name: 'Old')
      service = described_class.new(app: app)
      service.stage(name: 'New')

      expect(service.commit!).to be(true)
      expect(app.reload.name).to eq('New')
    end

    it 'discards the current draft, leaving the App untouched' do
      app = create(:app, name: 'Old')
      service = described_class.new(app: app)
      service.stage(name: 'New')

      expect(service.discard!).to be(true)
      expect(app.reload.name).to eq('Old')
    end
  end
end
