# frozen_string_literal: true

# Task 31a: the top-level registry the v2 index's per-app `collections[]`
# field has been reserving a slot for since 29a/29b -- a named, described
# grouping of apps (D-store's own `Collection` type, 4.c.ii.zo, already
# expects exactly this shape: slug/name/description + a curated app list).
# Membership itself lives on the join table (CollectionApp), not here.
class CreateCollections < ActiveRecord::Migration[7.1]
  def change
    create_table :collections do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.text :description

      t.timestamps
    end

    add_index :collections, :slug, unique: true
  end
end
