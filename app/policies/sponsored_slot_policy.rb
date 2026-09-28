# frozen_string_literal: true

# Same shape as CollectionPolicy/PlayUploadKeyPolicy -- admin-only namespace
# already gates access at the routing level, this just gives `authorize`
# calls somewhere to resolve.
class SponsoredSlotPolicy < ApplicationPolicy
  # Task 37b-iii-s7c-3: a slot belongs to a tenant through its app (operator's ❓3a: derived, no
  # column of its own). Default host: every slot, as before. A tenant's host: nothing for a
  # non-member, and for a member only the slots of that tenant's apps.
  class Scope < Scope
    def resolve
      tenant = Current.tenant
      return scope.all if tenant.nil?
      return scope.none unless user&.tenant_member?(tenant)

      scope.where(app_id: App.for_tenant(tenant).select(:id))
    end
  end
end
