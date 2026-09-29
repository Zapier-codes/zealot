# frozen_string_literal: true

# Task 30a. Same per-app "admin/owner/manage collaborator" rule
# AppPolicy#update? and ReleasePolicy already use -- staging, committing
# or discarding a listing edit is exactly as sensitive as editing the app
# directly (it *is* how the app gets edited, once 27e wires it up), so it
# gets no looser a check than `@app.update` already has today.
#
# Task 27e-c: now that a browser page calls it, it also carries the tenant rule the other write
# policies got in 37b-iii-s7c (same line as `ListingGraphicPolicy#manage_listing?`): on a tenant's
# host only a member of that tenant, and only for that tenant's app. On the default host both are
# always true, so nothing changes there.
class ListingEditPolicy < ApplicationPolicy
  def new?
    any_manage?
  end
  alias create? new?
  alias edit? new?
  alias update? new?
  alias show? new?

  def commit?
    any_manage?
  end

  def discard?
    any_manage?
  end

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
    @app ||= record.respond_to?(:app) ? record.app : record
  end
end
