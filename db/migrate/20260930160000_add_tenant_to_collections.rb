# frozen_string_literal: true

# Task 37b-iii-s6a: a collection belongs to at most one tenant (operator's resolved ❓3: collections
# follow ❓1, so `tenant_id` NULL means the DEFAULT tenant's registry). Every existing collection
# stays exactly where it is: no backfill, and the default tenant's index is unchanged.
#
# As with `apps.tenant_id` (s2) and `tenant_signing_keys`, the foreign key has no `on_delete`: a
# tenant must never silently delete its collections. `Tenant` refuses destroy while it owns any
# (`restrict_with_error`), and the database backs that up.
#
# `collections.slug` stays GLOBALLY unique on purpose (see handover.md, s6a "choices flagged").
#
# Adding a nullable column with no default is a catalog-only change in Postgres (no table rewrite).
class AddTenantToCollections < ActiveRecord::Migration[7.1]
  def change
    add_reference :collections, :tenant, null: true, foreign_key: true, index: true
  end
end
