# frozen_string_literal: true

# Task 31a: membership of an app in a Collection. Kept as its own join
# table (not a plain has_and_belongs_to_many) so a future slice can hang
# per-membership data off it (curator's note, position within the
# collection) without a second migration -- same reasoning App/User already
# uses a real `Collaborator` model instead of a bare HABTM join.
class CreateCollectionApps < ActiveRecord::Migration[7.1]
  def change
    create_table :collection_apps do |t|
      t.references :collection, null: false, foreign_key: true
      t.references :app, null: false, foreign_key: true

      t.timestamps
    end

    add_index :collection_apps, %i[collection_id app_id], unique: true
  end
end
