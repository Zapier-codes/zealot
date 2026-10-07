# frozen_string_literal: true

require 'rails_helper'

# Task 45a: the index's neutral `base_stats`. Written, NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe CatalogIndex::Serializer, 'base_stats' do
  let(:app) { Struct.new(:migrated_downloads, :migrated_rating_average, :migrated_rating_count).new(0, nil, 0) }
  let(:serializer) { described_class.allocate }

  def stats(record)
    serializer.send(:base_stats_for, record)
  end

  it 'is nil for an app with nothing carried over, and for a fixture without the columns' do
    expect(stats(app)).to be_nil
    expect(stats(Object.new)).to be_nil
  end

  it 'carries downloads alone, with no rating' do
    app.migrated_downloads = 12_400

    expect(stats(app)).to eq(downloads: 12_400, rating: nil)
  end

  it 'carries downloads and the rating average and count' do
    app.migrated_downloads = 12_400
    app.migrated_rating_average = BigDecimal('4.30')
    app.migrated_rating_count = 380

    expect(stats(app)).to eq(downloads: 12_400, rating: { average: 4.3, count: 380 })
  end
end
