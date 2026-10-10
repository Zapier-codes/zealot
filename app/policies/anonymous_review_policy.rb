# frozen_string_literal: true

# Z-P9 (principle 2): the owner's side of the anonymous review path. A review the automated moderator flagged
# is stored `pending` and is not public; an owner (or a tenant admin) decides it there. Rejecting it keeps it
# out of the index forever; publishing it lets it through. Same per-app manage rule as the reviews inbox
# (Apps::ReviewsController), because moderating a review is as sensitive as answering one.
class AnonymousReviewPolicy < ApplicationPolicy
  def index?
    any_manage?
  end
  alias show? index?
  alias publish? index?
  alias reject? index?

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def app
    @app ||= record.respond_to?(:app) ? record.app : record
  end

  def any_manage?
    tenant_access? && in_request_tenant?(app) && manage?(app: app)
  end
end
