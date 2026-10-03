# frozen_string_literal: true

# The org-wide Android signing key signs every release this organization ships, so who may see, add or
# remove it is stated here explicitly: platform admins only (an admin ON THE DEFAULT HOST, `role =
# admin` and no tenant on the request: `User#platform_admin?`, ❓4b-b, "platform-wide power never rides
# in on a tenant request").
#
# Two controllers ask this policy. Admin::AndroidSigningKeysController lives under the routing-level
# `authenticate :user, ->(user) { user.admin? }` gate (config/routes.rb), so for it these overrides only
# add the tenant rule. Api::AndroidSigningKeysController (Task 34d-1) is token-authenticated and nothing
# upstream of Pundit restricts it to admins, so for it the overrides below are load-bearing, the same
# reason PlayCredentialPolicy states. `manage?` (true for any developer) is deliberately not enough.
class AndroidSigningKeyPolicy < ApplicationPolicy
  def show?
    platform_admin?
  end

  def new?
    platform_admin?
  end

  def create?
    platform_admin?
  end

  def destroy?
    platform_admin?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def platform_admin?
    user.present? && user.platform_admin?(request_tenant)
  end
end
