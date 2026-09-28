# frozen_string_literal: true

# Task 37b-iii-s7c-0 (❓4b-a): who belongs to which tenant. One row per (user, tenant) with a role,
# so a person can work for two tenants (an agency) and an empty tenant can still be staffed. NO
# callers yet: nothing reads this table until s7c-1/s7c-2 (the request-tenant reader and the access
# rule), so every request behaves exactly as it did.
#
# Both foreign keys have no `on_delete`, like `apps.tenant_id` and `tenant_signing_keys.tenant_id`:
# the database never silently drops a tenant's staff. `Tenant` refuses destroy while it has members
# (`restrict_with_error`); `User` removes a departing user's own memberships in the model.
#
# The unique index on (user_id, tenant_id) also serves lookups by user, so `user_id` gets no index
# of its own. `role` is a closed set enforced here as well as in the model (an OR chain, not
# `IN (...)`, so `schema:dump` stays a fixed point; see `create_tenant_signing_keys`).
class CreateTenantMemberships < ActiveRecord::Migration[7.1]
  def change
    create_table :tenant_memberships do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.references :tenant, null: false, foreign_key: true, index: true
      t.string :role, null: false, default: 'member'
      t.timestamps
    end

    add_index :tenant_memberships, %i[user_id tenant_id], unique: true

    add_check_constraint :tenant_memberships, "role = 'member' OR role = 'owner'",
                         name: 'tenant_memberships_role_known'
  end
end
