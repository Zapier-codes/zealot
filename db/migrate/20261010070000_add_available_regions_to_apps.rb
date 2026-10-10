# frozen_string_literal: true

# Z-P20 (Play Console parity): country availability. Play lets an owner restrict an app to a set of countries;
# the index already reserved `available_regions` ("null = all regions") but nothing ever set it. This adds the
# backing column (an array of ISO-3166-1 alpha-2 codes; empty/NULL = all regions) and the serializer publishes
# it. The Console field that edits it lives on the App-content screen beside the other listing declarations.
#
# Zealot does not geo-block the download itself -- it publishes the list so a reader (D-Store) can warn that an
# app is not offered in the visitor's country; the availability decision stays a listing fact, never a false
# promise that the bytes are unreachable.
class AddAvailableRegionsToApps < ActiveRecord::Migration[8.1]
  def change
    add_column :apps, :available_regions, :jsonb, default: [], null: false
  end
end
