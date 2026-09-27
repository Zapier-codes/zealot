# frozen_string_literal: true

require 'rails_helper'

# Task 30a: "change a copy of the listing, validate, then commit or
# discard". Builds real App/ListingEdit records via FactoryBot (both
# factories exist, unlike Release), same as app_publisher_alias_spec.rb
# and the other App-focused specs in this directory.
RSpec.describe ListingEdit do
  describe '#staged_attributes_keys_allowed (validation)' do
    it 'rejects a key outside the listing' do
      app = create(:app)
      edit = build(:listing_edit, app: app, staged_attributes: { 'listing_status' => 'live' })

      expect(edit).not_to be_valid
      expect(edit.errors[:staged_attributes].join).to include('listing_status')
    end

    it 'accepts every field App::CATALOG_INDEX_LISTING_FIELDS plus description' do
      app = create(:app)
      edit = build(:listing_edit, app: app, staged_attributes: {
                     'name' => 'New name', 'description' => 'New copy', 'category' => 'tools'
                   })

      expect(edit).to be_valid
    end
  end

  describe '#staged_attributes_valid_against_app (validation)' do
    it 'rejects a staged value that would fail App validation (category inclusion)' do
      app = create(:app)
      edit = build(:listing_edit, app: app, staged_attributes: { 'category' => 'not_a_real_category' })

      expect(edit).not_to be_valid
      expect(edit.errors[:staged_attributes].join).to include('category')
    end

    it 'does not surface an App validation error on a field this edit never staged' do
      # A pre-existing, already-invalid play_package_name on the live app
      # (set via update_column, bypassing App's own validation, the way
      # legacy data could end up invalid) must not block a draft that
      # only stages `name` -- that conflict isn't this edit's problem.
      create(:app, play_package_name: 'com.example.taken')
      app = create(:app)
      app.update_column(:play_package_name, 'com.example.taken')
      edit = build(:listing_edit, app: app, staged_attributes: { 'name' => 'New name' })

      expect(edit).to be_valid
    end

    it 'leaves an empty draft valid (nothing staged yet)' do
      edit = build(:listing_edit, app: create(:app), staged_attributes: {})

      expect(edit).to be_valid
    end
  end

  describe 'one draft per app' do
    it 'refuses a second draft for the same app' do
      app = create(:app)
      create(:listing_edit, app: app)
      second = build(:listing_edit, app: app)

      expect(second).not_to be_valid
      expect(second.errors[:app_id]).to be_present
    end

    it 'does not count a committed or discarded edit against the limit' do
      app = create(:app)
      create(:listing_edit, app: app, status: 'committed', committed_at: Time.current)
      create(:listing_edit, app: app, status: 'discarded', discarded_at: Time.current)
      third = build(:listing_edit, app: app)

      expect(third).to be_valid
    end
  end

  describe '#commit!' do
    it 'applies staged_attributes to the live App and marks itself committed, in one go' do
      app = create(:app, name: 'Old name', category: 'tools')
      edit = create(:listing_edit, app: app, staged_attributes: { 'name' => 'New name', 'category' => 'social' })

      expect(edit.commit!).to be(true)

      expect(app.reload.name).to eq('New name')
      expect(app.category).to eq('social')
      expect(edit.reload).to be_status_committed
      expect(edit.committed_at).to be_present
    end

    it 'leaves the live App and itself untouched when staged_attributes fails App validation' do
      app = create(:app, name: 'Old name')
      edit = create(:listing_edit, app: app, staged_attributes: { 'category' => 'not_a_real_category' })

      expect(edit.commit!).to be(false)
      expect(app.reload.name).to eq('Old name')
      expect(edit.reload).to be_status_draft
    end

    it 'refuses to commit an already-committed or discarded edit' do
      app = create(:app)
      edit = create(:listing_edit, app: app, staged_attributes: { 'name' => 'X' })
      edit.commit!

      expect(edit.commit!).to be(false)
    end

    it 'is a harmless no-op success for an empty draft' do
      edit = create(:listing_edit, app: create(:app), staged_attributes: {})

      expect(edit.commit!).to be(true)
      expect(edit.reload).to be_status_committed
    end
  end

  describe '#discard!' do
    it 'marks itself discarded without touching the live App' do
      app = create(:app, name: 'Untouched')
      edit = create(:listing_edit, app: app, staged_attributes: { 'name' => 'Would-be new name' })

      expect(edit.discard!).to be(true)

      expect(app.reload.name).to eq('Untouched')
      expect(edit.reload).to be_status_discarded
      expect(edit.discarded_at).to be_present
    end

    it 'refuses to discard an already-committed edit' do
      edit = create(:listing_edit, app: create(:app), staged_attributes: {})
      edit.commit!

      expect(edit.discard!).to be(false)
    end
  end

  describe '#previewed_attributes' do
    it 'merges staged values over the live App without staging App itself' do
      app = create(:app, name: 'Live name', category: 'tools')
      edit = build(:listing_edit, app: app, staged_attributes: { 'name' => 'Staged name' })

      preview = edit.previewed_attributes

      expect(preview['name']).to eq('Staged name')
      expect(preview['category']).to eq('tools')
      expect(app.name).to eq('Live name') # never mutated
    end
  end
end
