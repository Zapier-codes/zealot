# frozen_string_literal: true

# Z-P18 (SSO/SAML half): the SAML sign-in panel is a platform-admin view (it names the org's SP entity id and
# ACS URL, the values the IdP must trust). Read-only; the configuration itself is edited through Settings.
class SamlPolicy < ApplicationPolicy
  def show?
    user.present? && user.platform_admin?(request_tenant)
  end

  def metadata?
    show?
  end
end
