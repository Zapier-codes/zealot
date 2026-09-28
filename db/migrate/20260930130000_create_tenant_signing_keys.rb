# frozen_string_literal: true

# Task 37b-ii-k2: the per-tenant Ed25519 signing key (`TenantSigningKey`), designed in
# docs/tenant_signing_keys.md. One row per key; a tenant has several over time (pending -> active
# -> retiring -> retired). NO callers yet: nothing reads this table until k3/k4.
#
# The DB enforces the invariants it cheaply can (doc section 2): at most one `active`, one
# `pending` and one `retiring` key per (tenant, purpose) through partial unique indexes; a
# globally unique `public_key` (no two tenants can share a key); the closed sets of `status` and
# `purpose`; and a private key present on every key that can still sign. A RETIRED key has its
# private key destroyed (doc section 2), so `private_key_pem` is nullable and the constraint
# says only a retired row may lack it.
#
# No `on_delete` on the tenant foreign key on purpose: deleting a tenant must not silently
# destroy key material, and what deleting a tenant means is 37b-iii's decision.
class CreateTenantSigningKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :tenant_signing_keys do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :purpose, null: false, default: 'catalog_index'
      t.string :status, null: false
      t.text :private_key_pem
      t.string :public_key, null: false
      t.string :key_id, null: false
      t.datetime :last_signed_at
      t.integer :sequence, null: false, default: 0
      t.datetime :activated_at
      t.datetime :retired_at
      t.timestamps
    end

    add_index :tenant_signing_keys, :public_key, unique: true
    add_index :tenant_signing_keys, %i[tenant_id purpose], name: 'index_tenant_signing_keys_one_active',
                                                            unique: true, where: "status = 'active'"
    add_index :tenant_signing_keys, %i[tenant_id purpose], name: 'index_tenant_signing_keys_one_pending',
                                                            unique: true, where: "status = 'pending'"
    add_index :tenant_signing_keys, %i[tenant_id purpose], name: 'index_tenant_signing_keys_one_retiring',
                                                            unique: true, where: "status = 'retiring'"

    # An OR chain, not `IN (...)`: Postgres prints an IN list as an ARRAY cast that it re-normalizes
    # differently when loaded back from schema.rb, so `schema:dump` would never be a fixed point.
    add_check_constraint :tenant_signing_keys,
                         "status = 'pending' OR status = 'active' OR status = 'retiring' OR status = 'retired'",
                         name: 'tenant_signing_keys_status_known'
    add_check_constraint :tenant_signing_keys, "purpose IN ('catalog_index')",
                         name: 'tenant_signing_keys_purpose_known'
    add_check_constraint :tenant_signing_keys, "status = 'retired' OR private_key_pem IS NOT NULL",
                         name: 'tenant_signing_keys_private_key_unless_retired'
  end
end
