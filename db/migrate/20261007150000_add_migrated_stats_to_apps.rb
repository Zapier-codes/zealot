# frozen_string_literal: true

# Task 45a: downloads and ratings an app earned before it was listed here (real history from a manual
# distribution), entered by a platform admin with a note saying where the figures come from. Kept in their own
# columns so the backend always knows which part of a total is carried over; the public index publishes only
# the neutral `base_stats`, and D-Store shows one combined number.
class AddMigratedStatsToApps < ActiveRecord::Migration[8.1]
  def change
    change_table :apps, bulk: true do |t|
      t.bigint :migrated_downloads, null: false, default: 0
      t.decimal :migrated_rating_average, precision: 3, scale: 2
      t.integer :migrated_rating_count, null: false, default: 0
      t.text :migrated_source_note
      t.bigint :migrated_recorded_by_id
      t.datetime :migrated_recorded_at
    end
  end
end
