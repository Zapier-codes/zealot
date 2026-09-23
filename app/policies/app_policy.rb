# frozen_string_literal: true

class AppPolicy < ApplicationPolicy
  def index?
    app_user?
  end

  def show?
    app_user?
  end

  # A brand-new app isn't about an existing app, so it keeps the global
  # admin/developer check. For an already-saved app (nested creates that
  # authorize the parent app with `create?`, and the API right after
  # App#create_owner) it is the per-app check instead.
  def create?
    return any_manage? if record.respond_to?(:persisted?) && record.persisted?

    manage?
  end

  # Task 23: changing or deleting an app is limited to its admin/owner/manage
  # collaborators — no longer any developer on the instance.
  def edit?
    any_manage?
  end

  def update?
    any_manage?
  end

  def destroy?
    any_manage?
  end

  def new_owner?
    admin? || app_owner?
  end

  def update_owner?
    admin? || app_owner?
  end

  def archive?
    any_manage?
  end

  def archived?
    any_manage?
  end

  def unarchive?
    any_manage?
  end

  class Scope < Scope
    def resolve
      scope.all
    end
  end

  private

  # Reading stays as before: any admin/developer, guests in guest mode, and
  # the app's collaborators.
  def app_user?
    guest_mode? || manage? || manage?(app: record) || app_collaborator?(user, record)
  end

  # Writing (Task 23) is per app.
  def any_manage?
    manage?(app: record)
  end

  def app_owner?
    app_owner_of?(record)
  end
end
