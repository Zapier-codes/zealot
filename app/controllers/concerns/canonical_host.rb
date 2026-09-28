# frozen_string_literal: true

# Task 37b-iii-s7b: a channel's public pages and downloads live on their owning tenant's host. A
# `GET` for one on another host is redirected there (302) rather than refused, so install links
# that were already shared keep working. The default tenant's channel asked for on a tenant's host
# goes to the default host. Nothing else redirects: a request on the channel's own tenant (or the
# default host for a default-tenant channel) is untouched, a non-GET is never redirected, and a
# tenant with no usable host (`Channel#canonical_host` is nil) fails open to today's behaviour.
#
# The target host comes from our own tenant data, never from the request, so this is not an open
# redirect; `Tenant#canonical_host` only returns a host that resolves back to the tenant, so it
# cannot loop. Needs `current_tenant` (TenantScoped).
module CanonicalHost
  extend ActiveSupport::Concern

  private

  def redirect_to_canonical_host(channel)
    return unless request.get? || request.head?
    return if channel.nil? || channel.app&.tenant_id == current_tenant&.id

    host = channel.canonical_host
    return if host.blank? || host == request.host.to_s.downcase

    redirect_to canonical_host_url(host), status: :found, allow_other_host: true
  end

  def canonical_host_url(host)
    port = request.optional_port ? ":#{request.optional_port}" : ''
    "#{request.protocol}#{host}#{port}#{request.fullpath}"
  end
end
