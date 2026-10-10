# frozen_string_literal: true

# Z-P24 (enterprise device management): the managed-configuration panel names the organisation's policy (which
# sources are enabled, whether desktop sources show, which packages are hidden) — org-wide, admin-only
# knowledge, the same audience as the SAML panel. Read-only; the policy is edited through Settings.
class ManagedConfigPolicy < ApplicationPolicy
  def show?
    user.present? && user.platform_admin?(request_tenant)
  end

  def download?
    show?
  end
end
