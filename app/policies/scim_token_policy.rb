# frozen_string_literal: true

# Z-P18 (SCIM half): minting, listing and revoking the tokens an identity provider provisions with is a
# platform-admin act -- a SCIM token can create and disable accounts, so `manage?` (true for any developer)
# is deliberately not enough. Same rule as AndroidSigningKeyPolicy: an admin ON THE DEFAULT HOST only.
class ScimTokenPolicy < ApplicationPolicy
  def index?
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
