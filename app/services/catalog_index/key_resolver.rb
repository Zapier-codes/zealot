# frozen_string_literal: true

module CatalogIndex
  # Task 37b-ii-k4: which key signs a tenant's catalog index (docs/tenant_signing_keys.md).
  #
  #   * the DEFAULT tenant (nil, blank, 'default', or anything whose `tenant_id` is 'default')
  #     -> `CatalogIndexSigningKey.current`, exactly as before. D-store already pins that key, so
  #     it is never moved (decision 1). With no key yet this returns nil / [], NOT an error, so
  #     `Signer`'s existing "run rake catalog_index:generate_key" message still applies.
  #   * any other tenant -> that tenant's `active` `TenantSigningKey` for purpose `catalog_index`.
  #     A missing tenant, or a tenant with no `active` key, raises `NoKeyError` NAMING the tenant:
  #     it must never fall back to the default tenant's key (that would sign tenant B's index
  #     with the key D-store pins for the default tenant).
  #
  # `tenant` may be a tenant id String, a `Tenant`, or a `Zealot::TenantResolver::Ref` (what
  # `env['zealot.tenant']` holds): anything answering `tenant_id`. Lookups go through the tenant
  # record, so tenant A's request can never select tenant B's key.
  module KeyResolver
    PURPOSE = 'catalog_index'

    # Subclass of `Signer::NoKeyError`, so anything already rescuing that keeps working.
    class NoKeyError < CatalogIndex::Signer::NoKeyError; end

    class << self
      # The key of record (the one whose signature goes in `index.json.sig`), or nil for a default
      # tenant that has no key yet.
      def for(tenant = nil)
        signing_keys_for(tenant).first
      end

      # Every key that must sign right now, primary (`active`) first: the `active` key, plus the
      # `retiring` one during a rotation overlap (k5). One element for the default tenant.
      def signing_keys_for(tenant = nil)
        id = tenant_id_of(tenant)
        return [CatalogIndexSigningKey.current].compact if default?(id)

        record = ::Tenant.find_by(tenant_id: id) or raise NoKeyError, "no tenant #{id.inspect}, so no signing key"
        keys = TenantSigningKey.for_tenant(record, PURPOSE).where(status: TenantSigningKey::SIGNING_STATUSES).order(:id).to_a
        active = keys.find(&:active?) or raise NoKeyError, "tenant #{id.inspect} has no active #{PURPOSE} signing key"

        [active, *keys.reject { |k| k.equal?(active) }]
      end

      def default?(tenant)
        id = tenant_id_of(tenant)
        id.empty? || id == Zealot::TenantResolver::DEFAULT_TENANT_ID
      end

      private

      def tenant_id_of(tenant)
        (tenant.respond_to?(:tenant_id) ? tenant.tenant_id : tenant).to_s.strip.downcase
      end
    end
  end
end
