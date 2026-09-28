# frozen_string_literal: true

# Task 37b-iii-s6a: "this row belongs to at most one tenant; NULL is the default tenant's". The same
# rule `App.for_tenant` (s3) applies, in one place for the editorial tables that follow the apps
# (operator's resolved ❓3). "Default" is decided by `CatalogIndex::KeyResolver.default?`, so this
# can never disagree with the key resolver or with `App.for_tenant`.
#
# `App` still declares its own `belongs_to :tenant` and scope (s2/s3) and is deliberately NOT moved
# onto this concern in this slice: it is a live model and nothing here needs it to change.
module TenantOwned
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, optional: true

    # * default tenant (nil, "default", or a Ref to it) -> rows with no tenant;
    # * any other tenant -> only that tenant's rows;
    # * an unknown tenant -> nothing, NEVER the default tenant's rows.
    # `tenant` may be a `Tenant`, a tenant id String, or a `Zealot::TenantResolver::Ref`.
    scope :for_tenant, ->(tenant) {
      if CatalogIndex::KeyResolver.default?(tenant)
        where(tenant_id: nil)
      elsif tenant.is_a?(::Tenant)
        where(tenant_id: tenant.id)
      else
        where(tenant_id: ::Tenant.where(tenant_id: CatalogIndex::KeyResolver.tenant_id_of(tenant)).select(:id))
      end
    }
  end
end
