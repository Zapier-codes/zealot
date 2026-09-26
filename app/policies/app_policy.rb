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

  # Task 24: who may put a different front-facing publisher name on an app
  # ("publish for a friend"). The intended rule is "an approved company"; the
  # company verification (KYB) flow doesn't exist yet, so until it does this is
  # admin-only rather than open to every uploader — an alias on public pages
  # with no verification behind it is an impersonation risk. Replace this one
  # predicate when verification lands.
  def set_publisher_alias?
    admin?
  end

  # Task 31a: featured / Editors' Pick are store-owned editorial data (the
  # outcome of ❓6), not something an app's own owner can set on themselves
  # -- admin-only, same reasoning as set_publisher_alias? above. Enforced
  # here (not just by Admin::AppsController living in the admin namespace)
  # so the rule holds even if a future non-admin surface calls it.
  def set_editorial_flags?
    admin?
  end

  # Task 25: putting an app on our own store is the owner's call (the person
  # who uploaded it); admins can see the listing and record the payment.
  def list_on_store?
    app_owner?
  end

  def view_store_listing?
    admin? || app_owner?
  end

  # Temporary manual stand-in for the payment provider (not chosen yet).
  def mark_paid?
    admin?
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
