# frozen_string_literal: true

# Task 37b-ii-t1: the `Tenant` table -- one row per white-label operator resolved by host
# (Zealot::TenantResolver). Fields follow TenantConfig v1 (Storeapp spec/tenant-config-schema.md,
# Task 37a), minus the per-publish fields (`schema_version`, `generated_at`, `sequence`,
# `expires_at`: those belong to the signed record 37c serves, not to the stored tenant) and minus
# `is_default_tenant` (the default tenant is compiled into the resolver and is never a row).
#
# The DB enforces what it cheaply can: tenant_id shape and the reserved 'default', and `domains`
# being a JSON array. Domain uniqueness ACROSS tenants cannot be a plain unique index on a jsonb
# array, so the model validates it; the resolver's "contested domain -> default tenant" rule is
# the safety net for the race that leaves.
class CreateTenants < ActiveRecord::Migration[7.1]
  def change
    create_table :tenants do |t|
      t.string :tenant_id, null: false, limit: 63
      t.string :display_name, null: false
      t.string :primary_color_hex, null: false
      t.string :logo_url
      t.string :logo_sha256
      t.string :cdn_base, null: false
      t.string :catalog_index_base_url
      t.jsonb :domains, null: false, default: []
      t.timestamps
    end

    add_index :tenants, :tenant_id, unique: true

    add_check_constraint :tenants,
      "tenant_id ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$' AND tenant_id <> 'default'",
      name: 'tenants_tenant_id_format'
    add_check_constraint :tenants, "jsonb_typeof(domains) = 'array'",
      name: 'tenants_domains_is_array'
  end
end
