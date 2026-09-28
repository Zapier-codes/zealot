# frozen_string_literal: true

# Task 37b-iii-s7c-1: the FIRST reader of `env['zealot.tenant']` in `app/` (s7 survey, finding 1).
# The Rack shim (`TenantHostMiddleware`) resolves the request's host to a tenant; this concern turns
# that into something a controller can ask: which tenant is this request for, and is it the default
# host? NO behaviour change: nothing calls either method yet. The access rule (s7c-2) and the
# per-surface slices (s7c-3 to s7c-6, s7b) are the callers.
#
#   * `current_tenant`: the `Tenant` row for the request's host, or `nil` on the default host.
#   * `default_host?`: true when `current_tenant` is `nil`.
#
# The DEFAULT tenant is never a row, so "default host" is `nil`, not an object. An unknown host, no
# host, an unset `env` key, or a resolver ref whose tenant row has just been deleted (the registry
# is cached for a short TTL) all read as the default host, the same "never a 404" rule the resolver
# already follows. The default host costs no query.
#
# Deliberately private, exposed to views with `helper_method` when the controller supports it: a
# public method on a controller is a routable action name. `Api::BaseController` is an
# `ActionController::API` and does not include this yet; s7c-5 will include it there.
module TenantScoped
  extend ActiveSupport::Concern

  included do
    helper_method :current_tenant, :default_host? if respond_to?(:helper_method)
    # Task 37b-iii-s7c-2: policies read the request's tenant from `Current.tenant` (Pundit passes
    # them only `user` and `record`). Set first, before any authorization runs; a no-op on the
    # default host, which is the value `Current.tenant` already has.
    before_action :set_current_tenant if respond_to?(:before_action)
  end

  private

  # @return [Tenant, nil] the tenant this request's host belongs to; `nil` on the default host
  def current_tenant
    return @current_tenant if defined?(@current_tenant)

    @current_tenant = tenant_row_for(request.env[Zealot::TenantResolver::ENV_TENANT_KEY])
  end

  def default_host?
    current_tenant.nil?
  end

  def set_current_tenant
    Current.tenant = current_tenant
  end

  # One `SELECT` per request, and only for a non-default host. A database error is NOT rescued: the
  # caller of this method decides access (s7c-2), so failing open to "default host" here would
  # widen it. (The resolver itself fails closed to the default tenant, in the Rack layer.)
  def tenant_row_for(ref)
    id = CatalogIndex::KeyResolver.tenant_id_of(ref)
    return nil if CatalogIndex::KeyResolver.default?(id)

    ::Tenant.find_by(tenant_id: id)
  end
end
