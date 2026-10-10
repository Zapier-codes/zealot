# frozen_string_literal: true

require 'rails_helper'

# D-Store leaf 5.i.i.zo (Zealot side): the category vocabulary as its own separately-versioned,
# signed document, so adding a category is a manifest publish, not a catalog-index schema bump.
RSpec.describe CatalogIndex::Taxonomy do
  it 'renders every category the app model accepts, with slug and display name' do
    result = described_class.call(sequence: 5)

    manifest = JSON.parse(result.manifest_json)
    expect(manifest['schema_version']).to eq(1)
    expect(manifest['sequence']).to eq(5)
    expect(manifest['app_types']).to eq(%w[app game])

    app_slugs = manifest['app_categories'].map { |e| e['slug'] }
    game_slugs = manifest['game_categories'].map { |e| e['slug'] }
    expect(app_slugs).to eq(App::APP_CATEGORIES.map(&:last))
    expect(game_slugs).to eq(App::GAME_CATEGORIES.map(&:last))
    expect(result.category_count).to eq(App::CATEGORY_VALUES.size)
  end

  it 'names every category, not just its slug (so a reader need not copy the list)' do
    manifest = JSON.parse(described_class.call.manifest_json)

    expect(manifest['app_categories']).to include('slug' => 'tools', 'name' => 'Tools')
    expect(manifest['game_categories']).to include('slug' => 'game_puzzle', 'name' => 'Puzzle')
  end

  it 'never lists a category the app model would reject' do
    manifest = JSON.parse(described_class.call.manifest_json)
    slugs = (manifest['app_categories'] + manifest['game_categories']).map { |e| e['slug'] }

    expect(slugs).to all(be_in(App::CATEGORY_VALUES))
  end
end
