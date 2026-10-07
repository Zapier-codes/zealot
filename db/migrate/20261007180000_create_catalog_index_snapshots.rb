# frozen_string_literal: true

# Task 45g: the last signed catalog index of each tenant, kept as the exact bytes that were signed, so Zealot can
# serve them itself (GET /catalog/index.json and index.json.sig on the Render host) as well as publishing them to
# the Pages repo. One row per tenant, overwritten by each publish (which already runs under an advisory lock, so
# an older index can never replace a newer one).
class CreateCatalogIndexSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :catalog_index_snapshots do |t|
      t.string :tenant_key, null: false
      t.text :index_json, null: false
      t.text :signature, null: false
      t.string :signing_key_id
      t.datetime :generated_at, null: false
      t.timestamps
    end
    add_index :catalog_index_snapshots, :tenant_key, unique: true
  end
end
