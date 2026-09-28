# frozen_string_literal: true

class MetadatumPolicy < ApplicationPolicy

  def show?
    user_signed_in_or_guest_mode? || (user_signed_in? && (owner? || any_manage? || app_member?))
  end

  def new?
    user_signed_in?
  end

  def destroy?
    user_signed_in? && (owner? || any_manage? || app_member?)
  end

  class Scope < Scope
    # Task 37b-iii-s7c-4b: a teardown belongs to a tenant through its release's app. Default host:
    # all, as before. A tenant's host: nothing for a non-member, else only the tenant's releases'.
    def resolve
      tenant = Current.tenant
      return scope.all if tenant.nil?
      return scope.none unless user&.tenant_member?(tenant)

      scope.where(release_id: Release.for_tenant(tenant).select(:id))
    end
  end

  private

  def any_manage?
    return true if manage?
    return false unless app = record.app

    manage?(app: app)
  end

  def app_member?
    return false unless app = record.app

    app_collaborator?(user, app)
  end

  def owner?
    record.user == user
  end
end
