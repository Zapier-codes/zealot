# frozen_string_literal: true

# Task 38d (decision 3, debounced publish fan-out): `dirty_at` marks a tenant whose catalog index
# is out of date because a tenant BENEATH it published. NULL means clean, so every existing tenant
# stays clean: no backfill and nothing reads the column until `TenantIndexRepublishJob` (38d).
#
# It is a debounce marker, not a queue: setting it on an already-dirty tenant changes nothing, and
# the republish job claims and clears every dirty tenant in one statement. Nothing about the
# registry cache depends on it (it is written with `update_all`, which skips callbacks).
#
# A nullable column with no default is a catalog-only change in Postgres (no table rewrite).
class AddDirtyAtToTenants < ActiveRecord::Migration[7.1]
  def change
    add_column :tenants, :dirty_at, :datetime, null: true
  end
end
