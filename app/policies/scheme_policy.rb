# frozen_string_literal: true

class SchemePolicy < ApplicationPolicy

  def index?
    app_user?
  end

  def new?
    any_manage?
  end

  def create?
    any_manage?
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

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  def app_user?
    manage? || manage?(app: record.app) || app_collaborator?(user, record.app)
  end

  # Writing (Task 23) is per app: admin, owner or a manage collaborator.
  def any_manage?
    manage?(app: record.app)
  end
end
