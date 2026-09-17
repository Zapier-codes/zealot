# frozen_string_literal: true

class AddSigningFieldsToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :signed, :boolean, default: false, null: false
    add_column :releases, :signing_key_checksum, :string
  end
end
