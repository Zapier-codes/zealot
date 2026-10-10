# frozen_string_literal: true

require 'json'

module CatalogIndex
  # D-Store leaf `5.i.i.zo` (Zealot side; tracked in D-Store/HANDOVER.md for visibility). The catalog
  # index's own `category` is a closed JSON-Schema enum, so adding a category is a breaking schema bump
  # for every reader. Play keeps its category vocabulary out of the wire schema (its App Catalog Export
  # has a tiny closed `app_type` enum and a free-text `app_subcategory` string), so a category can be
  # added or renamed without re-versioning the export. This manifest is the same idea for Zealot: the
  # category vocabulary, in its own document with its own `schema_version`/`sequence`, signed with the
  # same key as the index, so adding a category is a manifest publish, not a catalog-index version bump.
  #
  # Published as `taxonomy.json` beside the index (see CatalogIndex::Publish). `app_type` itself (the
  # closed two-value "app"/"game") is published inline in each app of the index (`Serializer`), because a
  # reader needs it per app; this document carries the vocabulary those `category` strings are drawn
  # from. `App::APP_CATEGORIES`/`GAME_CATEGORIES` stay the source of truth and this is rendered from
  # them, so the manifest can never list a category the app model rejects.
  #
  # Written, not run: this repo's gems and Postgres are not installed in the sandbox (standing
  # limitation), so it is syntax-checked and reviewed against `Serializer`/`Signer`, not executed.
  class Taxonomy
    MANIFEST_VERSION = 1

    Result = Struct.new(:manifest_json, :generated_at, :sequence, :category_count, keyword_init: true)

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(now: Time.now.utc, sequence: 0)
      @now = now
      @sequence = sequence
    end

    def call
      manifest = {
        schema_version: MANIFEST_VERSION,
        generated_at: @now.utc.iso8601,
        sequence: @sequence,
        app_types: %w[app game],
        app_categories: entries_for(App::APP_CATEGORIES),
        game_categories: entries_for(App::GAME_CATEGORIES)
      }
      Result.new(manifest_json: "#{JSON.pretty_generate(manifest)}\n", generated_at: @now,
                 sequence: @sequence, category_count: manifest[:app_categories].size + manifest[:game_categories].size)
    end

    private

    # `App::APP_CATEGORIES`/`GAME_CATEGORIES` are `[[display_name, slug], ...]`; the manifest carries
    # both so a reader can render a name without its own copy of the list (which is exactly the drift
    # this document exists to remove). Order is kept as the model declares it.
    def entries_for(pairs)
      pairs.map { |name, slug| { 'slug' => slug, 'name' => name } }
    end
  end
end
