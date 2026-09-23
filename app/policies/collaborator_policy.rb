# frozen_string_literal: true

class CollaboratorPolicy < ApplicationPolicy

  def show?
    manage? || manage?(app: app)
  end

  # Task 23: who is on an app is decided by an admin or the app's owner only.
  # Previously any developer could add themselves as a collaborator of any
  # app, which would have bypassed every per-app check.
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

  def any_manage?
    admin? || app_owner_of?(app)
  end

  def app
    @app ||= record.app
  end
end
