# frozen_string_literal: true

# Task 31a: the two editorial flags CatalogIndex::Serializer has been
# hardcoding to `false` since 29b ("reserved for 31a" -- see
# app/services/catalog_index/serializer.rb). Admin-only, instance-wide, not
# per-app-collaborator settings -- there is no owner-facing UI for either,
# same posture as Task 25's `listing_status`. Default false so every
# existing app keeps today's (already-shipped) `editorial: { featured:
# false, editors_pick: false }` behavior until an admin opts one in.
class AddEditorialFlagsToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :featured, :boolean, default: false, null: false
    add_column :apps, :editors_pick, :boolean, default: false, null: false
  end
end
