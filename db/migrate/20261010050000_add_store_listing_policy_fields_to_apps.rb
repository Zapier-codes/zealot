# frozen_string_literal: true

# Z-P5 + Z-P6 (Play Console parity, docs/PLAY-PARITY.md): the store-listing fields Play's "App content"
# section collects but Zealot had no home for -- the content/age rating, the Data Safety answers, and the
# two simple store flags. They are App columns (a listing property, not a per-release one), so
# `CatalogIndex::Serializer#serialize_app` can publish them under `listing` and `ListingEdit` can stage them
# the moment they join `App::CATALOG_INDEX_LISTING_FIELDS`.
#
# Every column is nullable with a falsy/empty default: an app whose owner has not filled the form yet reads
# as "unanswered", and the serializer publishes `null`/`false` -- never a guessed value. The schema is
# `additionalProperties: false` on `catalog_index_v2.schema.json`, so these map to fields that already exist
# there (`listing.content_rating`, `listing.data_safety`, `listing.contains_ads`,
# `listing.has_in_app_purchases`) -- no schema bump is needed.
class AddStoreListingPolicyFieldsToApps < ActiveRecord::Migration[8.1]
  def change
    change_table :apps, bulk: true do |t|
      # Z-P5: free-text age/content rating (e.g. "Everyone", "Teen", "Mature 17+"). A string, not an enum,
      # so it carries whatever the source already uses; the Storeapp client normalizes it to a filter class.
      t.string :content_rating

      # Z-P6: the Data Safety answers, in the shape `listing.data_safety` already declares.
      t.boolean :data_safety_collects
      t.jsonb :data_safety_types, default: [], null: false
      t.boolean :data_safety_shared
      t.boolean :data_safety_encrypted
      t.string :data_safety_deletion_url

      # Z-P5: Play's two listing flags.
      t.boolean :contains_ads
      t.boolean :has_in_app_purchases
    end
  end
end
