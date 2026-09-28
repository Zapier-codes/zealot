# frozen_string_literal: true

class ReleasePolicy < ApplicationPolicy

  def show?
    true
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

  # Task 37b-iii-s7c-5b (deny by default): changing or deleting a release also needs the tenant
  # rule, so a release of another tenant's app is refused on a tenant's host even if a lookup ever
  # forgot to scope it. On the default host `tenant_access?` and `in_request_tenant?` are always
  # true, so both predicates are `any_manage?` exactly as before. `new?`/`create?`/`edit?` are
  # untouched on purpose: the upload routes authorize them with a channel key and no user.
  def update?
    tenant_access? && in_request_tenant?(app) && any_manage?
  end

  def destroy?
    tenant_access? && in_request_tenant?(app) && any_manage?
  end

  # Task 27f-b: hold, release, halt, resume, pull or restore a release. The same rule as `update?`
  # (the app's admin, owner or a manage collaborator, plus the tenant rule), kept as its own
  # predicate so a later change to who may rewrite rollout does not silently change who may pull a
  # release from the store.
  def update_status?
    tenant_access? && in_request_tenant?(app) && any_manage?
  end

  def auth?
    true
  end

  # Deliberately admin? and not any_manage?, unlike every other action on
  # this policy: approving/rejecting a Play Store publish is an org-level
  # publishing decision (it's about this org's single verified Play
  # Console identity, not about who can manage the app the release
  # belongs to), so an app-scoped developer/collaborator shouldn't be able
  # to approve their own release for Play Store distribution. See
  # handover.md task #11.
  def approve_play_publish?
    admin?
  end

  def reject_play_publish?
    admin?
  end

  class Scope < Scope
    # Task 37b-iii-s7c-5b: a release belongs to a tenant through its app (release -> channel ->
    # scheme -> app). Default host: all, as before. A tenant's host: nothing for a non-member, else
    # only the releases of the tenant's apps. Read through `Release.for_tenant` (which reads
    # `App.for_tenant`) so "the tenant's releases" cannot mean something different here.
    def resolve
      tenant = Current.tenant
      return scope.all if tenant.nil?
      return scope.none unless user&.tenant_member?(tenant)

      scope.where(id: Release.for_tenant(tenant).select(:id))
    end
  end

  private

  def enabled_auth?
    record.channel.password.present?
  end

  # Task 23: uploading a new build (new?/create?), editing or deleting one is
  # limited to the app's admin, owner or manage collaborators — the person who
  # uploaded the app keeps control of its updates. It used to be `manage? ||
  # manage?(app:)`, which any developer on the instance satisfied.
  def any_manage?
    manage?(app: app)
  end

  def app
    @app ||= record.app
  end
end
