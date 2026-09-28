# frozen_string_literal: true

# Task 27d-d1: the store listing's graphics (screenshots and the feature graphic) exist as data, and
# an app can carry one YouTube video ID. Google Play attaches these to the store listing, not to a
# release, so the owner is the app (docs/store_listing_graphics.md). Nothing reads or writes these
# yet (27d-d2 adds the upload, 27d-e1 the index), so this changes no behaviour.
#
# Play's numbers (formats, pixel limits, counts) live in ListingGraphicRules, not in SQL: only
# what is a plain fact about the row is a constraint here (the kind and device vocabularies,
# positive sizes, at most one feature graphic per app and device). `sha256` and `storage_key` are
# null until 27d-d2 hashes and mirrors the file, the same two-step the release icon uses (27d-a).
class CreateListingGraphics < ActiveRecord::Migration[7.1]
  def change
    create_table :listing_graphics do |t|
      # The composite unique index below already starts with app_id, so no separate app_id index.
      t.references :app, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :kind, null: false
      t.string :device, null: false, default: 'phone'
      t.integer :position, null: false, default: 0
      t.string :alt_text
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.integer :width, null: false
      t.integer :height, null: false
      t.string :sha256
      t.string :storage_key
      t.timestamps

      t.index %i[app_id device], unique: true, where: "kind = 'feature_graphic'",
                                 name: 'index_listing_graphics_on_app_id_device_feature_graphic'
      t.index %i[app_id kind device position], unique: true,
                                               name: 'index_listing_graphics_on_app_id_kind_device_position'

      t.check_constraint 'byte_size > 0', name: 'listing_graphics_byte_size_positive'
      t.check_constraint "device = 'phone'", name: 'listing_graphics_device_known'
      t.check_constraint 'width > 0 AND height > 0', name: 'listing_graphics_dimensions_positive'
      t.check_constraint "kind = 'screenshot' OR kind = 'feature_graphic'", name: 'listing_graphics_kind_known'
    end

    add_column :apps, :promo_video_youtube_id, :string
  end
end
