# frozen_string_literal: true

# Z-P8. Reading an app's reviews and writing the developer reply is exactly as sensitive as editing the app,
# so it takes the same per-app rule the other write policies use (admin/owner/manage on this tenant's app).
class MigratedCommentPolicy < ApplicationPolicy
  def index?
    any_manage?
  end

  def update?
    any_manage?
  end
  alias reply? update?

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
    @app ||= record.is_a?(MigratedComment) ? record.app : record.respond_to?(:app) ? record.app : record
  end
end
