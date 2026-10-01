# frozen_string_literal: true

# Task 34a-7 (Storeapp leaf `f.xiv`): who may create, list and revoke an app's API tokens. The same
# per-app rule the console uses for editing the app (admin, owner or a manage collaborator) plus the
# tenant rule (on a tenant's host only a member of that tenant, and only for that tenant's app; on the
# default host both are always true). Kept as its own policy, not borrowed from `AppPolicy`, so a later
# change to who may edit an app cannot silently change who may mint a credential that publishes for it.
#
# A token can never reach this: the screen is a session page (`authenticate_user!`), not `/api`, and
# decision 34-4 lists token management as never available to an app token.
class AppApiTokenPolicy < ApplicationPolicy
  def index?
    any_manage?
  end

  def create?
    any_manage?
  end

  def destroy?
    any_manage?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def any_manage?
    tenant_access? && in_request_tenant?(app) && manage?(app: app)
  end

  def app
    @app ||= record.respond_to?(:app) ? record.app : record
  end
end
