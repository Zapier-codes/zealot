# frozen_string_literal: true

# Task 37b-iii-s7c-7. Who may staff a tenant's console is a platform decision (control plane, ❓4b-b):
# only a platform admin, and only on the default host. It is not inherited from `ApplicationPolicy`
# (whose `manage?` is true for any developer, and whose tenant rule would let a tenant's own admin
# member add more members). No index/show: the panel on the tenant edit page is the only view.
class TenantMembershipPolicy < ApplicationPolicy
  def create?
    platform_admin_on_default_host?
  end

  def update?
    platform_admin_on_default_host?
  end

  def destroy?
    platform_admin_on_default_host?
  end

  class Scope < Scope
    def resolve
      user&.admin? && Current.tenant.nil? ? scope.all : scope.none
    end
  end

  private

  def platform_admin_on_default_host?
    admin? && request_tenant.nil?
  end
end
