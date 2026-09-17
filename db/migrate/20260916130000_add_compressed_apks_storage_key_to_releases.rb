# frozen_string_literal: true

class AddCompressedApksStorageKeyToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :compressed_apks_storage_key, :string
  end
end
