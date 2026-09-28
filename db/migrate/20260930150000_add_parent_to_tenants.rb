# frozen_string_literal: true

# Task 38a: the "tree house" tenant hierarchy starts here. A tenant may have a parent tenant
# (`parent_tenant_id`), which may have its own parent, to any depth. NULL means a root tenant, so
# every existing tenant stays a root: no backfill, no data migration, and nothing changes for any
# reader. NO callers yet: nothing reads or sets the column until 38b (tree queries and the cycle
# check), 38c (the upward-cascading storefront read) and 38e (config fallback).
#
# The DEFAULT tenant is never a row (see `Tenant`), so no tenant can name it as a parent: it stays
# outside the tree, which is the assumption recorded on the Task 38 board.
#
# The foreign key has no `on_delete` on purpose, the same choice as `apps.tenant_id` and
# `tenant_signing_keys`: deleting a tenant must never silently delete or re-home its children.
# `Tenant` refuses destroy while it has children (`restrict_with_error`, decision 5), and the
# database backs that up.
#
# The one invariant the database can cheaply enforce is that a tenant is not its own parent. A
# LONGER cycle (A -> B -> A) cannot be a constraint, so the model validates it in 38b; until 38b
# lands nothing can set a parent, so no cycle can exist.
#
# Adding a nullable column with no default is a catalog-only change in Postgres (no table
# rewrite), and every value is NULL so the foreign-key validation has nothing to check.
class AddParentToTenants < ActiveRecord::Migration[7.1]
  def change
    add_reference :tenants, :parent_tenant, null: true, index: true, foreign_key: { to_table: :tenants }
    add_check_constraint :tenants, 'parent_tenant_id IS NULL OR parent_tenant_id <> id',
                         name: 'tenants_parent_not_self'
  end
end
