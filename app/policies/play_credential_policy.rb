# frozen_string_literal: true

# Same shape as AndroidSigningKeyPolicy/PlayUploadKeyPolicy for the
# session-authenticated admin controller — that namespace is already gated
# by `authenticate :user, ->(user) { user.admin? }` at the routing level
# (config/routes.rb), so the ApplicationPolicy default of `manage?` (true
# for any developer, not just admin) never actually got exercised there.
#
# This policy now also gates Api::PlayCredentialsController, which is
# token-authenticated rather than session-authenticated — nothing upstream
# of Pundit restricts that controller to admins, so the explicit admin?
# overrides below are load-bearing there. This credential is what
# authenticates every Play Developer API call this app makes, so
# `manage?` is deliberately not enough for either controller now.
class PlayCredentialPolicy < ApplicationPolicy
  def show?
    admin?
  end

  def create?
    admin?
  end

  def destroy?
    admin?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end
end
