# frozen_string_literal: true

# Task 27d-e2-a: who may add or remove a store-listing graphic. The same rule as changing the app
# itself (`AppPolicy#update?`): the app's admin, owner or a manage collaborator, plus the tenant rule
# (on a tenant's host, only a member of that tenant and only for that tenant's app; on the default
# host both are always true). Listing graphics are public store content, so a plain member
# collaborator may not change them. Reading needs no rule here: the bytes are public
# (`GET /download/graphics/:id`) and the owner's page is authorized through the app.
class ListingGraphicPolicy < ApplicationPolicy
  def create?
    manage_listing?
  end

  def destroy?
    manage_listing?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def manage_listing?
    tenant_access? && in_request_tenant?(record.app) && manage?(app: record.app)
  end
end
