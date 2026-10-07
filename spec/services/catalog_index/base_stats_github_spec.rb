# frozen_string_literal: true

require 'rails_helper'

# Task 45e: base_stats.downloads = carried-over history + what GitHub has counted. Written, NOT run.
RSpec.describe CatalogIndex::Serializer, 'base_stats with GitHub downloads' do
  let(:app) do
    Struct.new(:migrated_downloads, :migrated_rating_average, :migrated_rating_count, :github_download_total)
          .new(5_789_000, nil, 0, 3)
  end

  def stats(record)
    described_class.allocate.send(:base_stats_for, record)
  end

  it 'adds the GitHub total to the carried-over downloads' do
    expect(stats(app)).to eq(downloads: 5_789_003, rating: nil)
  end

  it 'shows GitHub downloads alone when nothing was carried over' do
    app.migrated_downloads = 0
    expect(stats(app)).to eq(downloads: 3, rating: nil)
  end
end
