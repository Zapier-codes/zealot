# frozen_string_literal: true

# Task 37b-iii-s2: an app can belong to exactly one tenant (operator's resolved ❓1: exclusive
# ownership). `apps.tenant_id` is nullable and NULL means "the default tenant's catalog", so every
# existing row stays exactly where it is: no backfill, no data migration, and the default tenant's
# index is unchanged. NO callers yet; nothing reads or writes the column until s3 (the read scope)
# and the admin/publish slices after it.
#
# The foreign key has no `on_delete` on purpose, the same choice as `tenant_signing_keys`:
# deleting a tenant must never silently delete or re-home its apps. `Tenant` refuses destroy while
# it owns apps (`restrict_with_error`), and the database backs that up.
#
# Adding a nullable column with no default is a catalog-only change in Postgres (no table
# rewrite), and every value is NULL so the foreign-key validation scan has nothing to check.
class AddTenantToApps < ActiveRecord::Migration[7.1]
  def change
    add_reference :apps, :tenant, null: true, foreign_key: true, index: true
  end
end
