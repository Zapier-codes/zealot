# frozen_string_literal: true

class AddAssetPackMetadataToReleases < ActiveRecord::Migration[7.1]
  def change
    add_column :releases, :asset_pack_type, :string
    add_column :releases, :brotli_compressed, :boolean, default: false, null: false
    add_column :releases, :original_size, :bigint
    add_column :releases, :compressed_size, :bigint

    add_index :releases, :asset_pack_type
  end
end
