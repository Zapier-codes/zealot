# frozen_string_literal: true

# Task 27e-b: Play's "short description" (80 characters), the store listing's one-line summary. The column is
# nullable and nothing but the index serializer (as the app's top-level `summary`) and the future 27e editor
# reads or writes it, so this changes no behaviour on its own. The length limit and the one-line rule live
# in ListingText and App, not in the database, the same split the other listing text (`description`) uses.
class AddShortDescriptionToApps < ActiveRecord::Migration[7.1]
  def change
    add_column :apps, :short_description, :string
  end
end
