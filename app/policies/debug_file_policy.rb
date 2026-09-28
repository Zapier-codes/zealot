# frozen_string_literal: true

class DebugFilePolicy < ApplicationPolicy

  def index?
    app_user?
  end

  def new?
    app_manage?
  end

  def create?
    app_manage?
  end

  def edit?
    any_manage?
  end

  def update?
    any_manage?
  end

  def destroy?
    any_manage?
  end

  def reprocess?
    any_manage?
  end

  def device?
    app_user?
  end

  def download?
    show?
  end

  class Scope < Scope
    # Task 37b-iii-s7c-4b: a debug file belongs to a tenant through its app. Default host: all, as
    # before. A tenant's host: nothing for a non-member, else only the tenant's apps' files.
    def resolve
      tenant = Current.tenant
      return scope.all if tenant.nil?
      return scope.none unless user&.tenant_member?(tenant)

      scope.where(app_id: App.for_tenant(tenant).select(:id))
    end
  end

  private

  def app_user?
    guest_mode? || any_manage? || app_collaborator?(user, app)
  end

  def any_manage?
    manage? || (app && manage?(app: app))
  end

  def app_manage?
    any_manage? || app_collaborator?(user, user.apps.map(&:id))
  end

  def app
    @app ||= record.app
  end
end
