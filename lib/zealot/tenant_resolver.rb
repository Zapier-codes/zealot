# frozen_string_literal: true

module Zealot
  # Host -> tenant resolution for the single multi-tenant Console deployment (Task 37b, the
  # "resolved by domain/config within the one deployment" half; mirrors Storeapp's
  # `1.c.iii.zo` and is the Rack-side twin of D-store's `6.b.ii.zi` `lib/tenant-host.ts` +
  # `findTenantForHost`, with the SAME rules so the three repos can never disagree about which
  # tenant a host belongs to):
  #
  #   * `normalize_host` lowercases, strips a `:port` and a trailing dot, and returns nil for
  #     anything that is not a plain DNS hostname (IPv6 literals, empty, junk).
  #   * exactly one tenant claims the host  -> that tenant
  #   * two or more tenants claim the host  -> the DEFAULT tenant (a contested domain resolves
  #     to neither claimant, independent of registry order)
  #   * optional `base_domain`: `<tenant_id>.<base_domain>` resolves by id, single label only
  #   * anything else (unknown host, nil, localhost, previews) -> the DEFAULT tenant, never a 404
  #   * a registry record claiming `tenant_id == 'default'` is dropped: the default tenant is
  #     compiled in and can't be overridden by data.
  #
  # Deliberately NO database access here. Records are anything responding to `tenant_id` and
  # `domains`; `registry` is a callable returning them. It defaults to none, and the app sets it
  # to the DB-backed, cached `Zealot::TenantRegistry` (37b-ii-t2, `config/initializers/
  # tenant_host.rb`), so the rules stay testable without a database.
  module TenantResolver
    DEFAULT_TENANT_ID = 'default'
    Ref = Struct.new(:tenant_id, :domains)
    DEFAULT_TENANT = Ref.new(DEFAULT_TENANT_ID, [].freeze).freeze

    HOST_PATTERN = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/.freeze

    ENV_HOST_KEY   = 'zealot.tenant_host'
    ENV_TENANT_KEY = 'zealot.tenant'
    # Rack's env form of the `X-Tenant-Host` header D-store uses; never trusted here, only deleted.
    CLIENT_HEADER_KEY = 'HTTP_X_TENANT_HOST'

    class << self
      # The app points this at `Zealot::TenantRegistry` (37b-ii-t2). Must be callable and return
      # an Enumerable.
      attr_writer :registry

      def registry
        @registry ||= -> { [] }
      end

      def base_domain
        ENV['TENANT_BASE_DOMAIN']
      end

      def normalize_host(raw)
        return nil if raw.nil?

        host = raw.to_s.strip.downcase
        return nil if host.start_with?('[') # IPv6 literal

        colon = host.index(':')
        host = host[0...colon] if colon
        host = host[0...-1] if host.end_with?('.')
        return nil if host.empty? || host.length > 253

        HOST_PATTERN.match?(host) ? host : nil
      end

      def resolve(host, tenants: registry.call, base_domain: self.base_domain)
        return DEFAULT_TENANT if host.nil?

        candidates = Array(tenants).reject { |t| t.tenant_id == DEFAULT_TENANT_ID }
        owners = candidates.select { |t| Array(t.domains).include?(host) }
        return owners.first if owners.size == 1
        return DEFAULT_TENANT if owners.size > 1

        base = normalize_host(base_domain)
        if base && host.end_with?(".#{base}")
          label = host[0...-(base.length + 1)]
          unless label.include?('.')
            by_id = candidates.find { |t| t.tenant_id == label }
            return by_id if by_id
          end
        end
        DEFAULT_TENANT
      end

      # Called by the Rack shim. Reads `HTTP_HOST` ONLY -- never `X-Forwarded-Host`, which any
      # client can set unless a trusted proxy overwrites it. Overwrites any pre-existing
      # `zealot.*` env keys and deletes a client-supplied `X-Tenant-Host`, so a visitor can
      # never choose their tenant. Fails closed to the default tenant on any registry error.
      def annotate!(env)
        env.delete(CLIENT_HEADER_KEY)
        host = normalize_host(env['HTTP_HOST'])
        tenant = begin
          resolve(host)
        rescue StandardError
          DEFAULT_TENANT
        end
        env[ENV_HOST_KEY] = host
        env[ENV_TENANT_KEY] = tenant
        env
      end
    end
  end
end
