# frozen_string_literal: true

class AppPolicy < ApplicationPolicy
  # Task 37b-iii-s7c-2: on a tenant's host, only a member of that tenant, and only for that tenant's
  # apps. On the default host `tenant_access?` and `in_request_tenant?` are true, so both methods
  # are `app_user?` exactly as before. The write rules (edit?, update?, ...) are s7c-6.
  def index?
    tenant_access? && app_user?
  end

  def show?
    tenant_access? && in_request_tenant?(record) && app_user?
  end

  # Task 37b-iii-s7c-4a (deny by default, cross-cutting rule 1): may this user open the console
  # pages that LIST apps (the apps list, the dashboard) on this host at all? Always true on the
  # default host; on a tenant's host only for a member of that tenant. It is a question about the
  # host, not about a record, so it is asked of the `App` class and does not look at `record`.
  # Without it, a non-member would be shown an empty list (the scope is `none`) instead of a refusal.
  def console?
    tenant_access?
  end

  # A brand-new app isn't about an existing app, so it keeps the global
  # admin/developer check. For an already-saved app (nested creates that
  # authorize the parent app with `create?`, and the API right after
  # App#create_owner) it is the per-app check instead.
  def create?
    return false unless tenant_write_access?
    return any_manage? if record.respond_to?(:persisted?) && record.persisted?

    manage?
  end

  # Task 23: changing or deleting an app is limited to its admin/owner/manage
  # collaborators — no longer any developer on the instance.
  def edit?
    tenant_write_access? && (any_manage?)
  end

  def update?
    tenant_write_access? && (any_manage?)
  end

  def destroy?
    tenant_write_access? && (any_manage?)
  end

  def new_owner?
    tenant_write_access? && (admin? || app_owner?)
  end

  def update_owner?
    tenant_write_access? && (admin? || app_owner?)
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

  # Task 45f: category and package name through the API are an admin's job, like the carried-over figures.
  def set_catalog_basics?
    admin?
  end

  # Task 45a: carried-over downloads and ratings are store-owned data an owner must not set on their own app,
  # admin-only like the editorial flags.
  def set_migrated_stats?
    admin?
  end

  # Task 25: putting an app on our own store is the owner's call (the person
  # who uploaded it); admins can see the listing and record the payment.
  def list_on_store?
    tenant_write_access? && (app_owner?)
  end

  def view_store_listing?
    tenant_write_access? && (admin? || app_owner?)
  end

  # Temporary manual stand-in for the payment provider (not chosen yet).
  def mark_paid?
    tenant_write_access? && (admin?)
  end

  def archive?
    tenant_write_access? && (any_manage?)
  end

  def archived?
    tenant_write_access? && (any_manage?)
  end

  def unarchive?
    tenant_write_access? && (any_manage?)
  end

  class Scope < Scope
    # The tenant rule (and, on the default host, the old `scope.all`) lives in the base class.
    def resolve
      super
    end
  end

  private

  # Task 37b-iii-s7c-6 (deny by default): every per-app WRITE rule also needs the tenant rule. On
  # the default host `tenant_access?` and `in_request_tenant?` are always true, so each predicate
  # is exactly what it was. On a tenant's host: only a member of that tenant, and (for a saved app)
  # only an app of that tenant. A class or a brand-new record has no tenant yet, so it only needs
  # the membership; the controller stamps the tenant before saving.
  def tenant_write_access?
    return false unless tenant_access?
    return true unless record.respond_to?(:persisted?) && record.persisted?

    in_request_tenant?(record)
  end

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
