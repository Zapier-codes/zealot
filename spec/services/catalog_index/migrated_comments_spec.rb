# frozen_string_literal: true

require 'rails_helper'

# Task 45d: the index publishes carried-over comments as `reviews` so a reader shows them as ordinary
# reviews. Written, NOT run (no Ruby in the sandbox that wrote it). Uses plain doubles, like base_stats_spec.rb,
# because the point is the mapping, not ActiveRecord.
RSpec.describe CatalogIndex::Serializer, 'reviews (carried-over comments)' do
  let(:serializer) { described_class.allocate }

  def comment(overrides = {})
    defaults = { author_name: 'Amina K.', rating: 5, body: 'Picked the right APK first time.',
                 commented_on: Date.new(2026, 9, 2), helpful_count: 41 }
    Struct.new(*defaults.keys).new(*defaults.merge(overrides).values)
  end

  def app_with(comments)
    relation = double('relation')
    allow(relation).to receive(:order).with(:commented_on, :id).and_return(comments)
    Struct.new(:migrated_comments).new(relation)
  end

  it 'is an empty array for an app with no comments and for a fixture without the association' do
    expect(serializer.send(:migrated_comments_for, app_with([]))).to eq([])
    expect(serializer.send(:migrated_comments_for, Object.new)).to eq([])
  end

  it 'publishes each comment oldest first with its author, rating, body, date and helpful count' do
    older = comment(commented_on: Date.new(2026, 9, 2))
    newer = comment(author_name: 'Zainab L.', rating: 3, body: 'Search is slow.', commented_on: Date.new(2026, 9, 18),
                    helpful_count: 23)

    # commented_on is a `date` column; the serializer publishes it as a date-time at UTC midnight
    # (`iso_date`), matching docs/catalog_index_v2.schema.json's `format: date-time` and D-Store's
    # carried-over reader, which reads it alongside the store's own `created_at` date-times.
    expect(serializer.send(:migrated_comments_for, app_with([older, newer]))).to eq(
      [{ author_name: 'Amina K.', rating: 5, body: 'Picked the right APK first time.',
         commented_on: '2026-09-02T00:00:00Z', helpful_count: 41 },
       { author_name: 'Zainab L.', rating: 3, body: 'Search is slow.',
         commented_on: '2026-09-18T00:00:00Z', helpful_count: 23 }]
    )
  end

  it 'publishes a null body rather than an empty string' do
    result = serializer.send(:migrated_comments_for, app_with([comment(body: '')]))
    expect(result.first[:body]).to be_nil
  end
end
