# frozen_string_literal: true

module TenantKeys
  # Task 37b-ii-k3: the four lifecycle steps for one tenant's signing key (docs/tenant_signing_keys.md
  # sections 2-3): `generate!`, `stage_next!`, `promote!`, `retire!`. Called by
  # `Admin::TenantKeysController` (k6); nothing else calls it yet.
  #
  # Every step is ONE transaction. It first locks the tenant's row (so two steps for the same
  # tenant serialize, including `generate!` when there are no key rows to lock yet), then the
  # tenant's key rows for this purpose in id order, then changes them. The lock order is always
  # tenant row -> key rows by ascending id, so it cannot deadlock against itself; a failed step
  # rolls back and leaves the previous state. Every step sets `sequence` on the rows it touches
  # to (highest existing for the tenant and purpose) + 1, the manifest counter of doc section 4.
  #
  # The invariants (exactly one `active` once a first key exists, never two, a key never goes
  # back) are also enforced by `TenantSigningKey` and by partial unique indexes; this service
  # just refuses, with a message that names the tenant, before the database has to.
  class Lifecycle
    # Proposal from docs/tenant_signing_keys.md section 3, for the operator to confirm.
    OVERLAP = 90.days

    class Error < StandardError; end
    # The step does not apply to the tenant's current keys.
    class InvalidState < Error; end
    # `retire!` before the overlap window has elapsed, without `force: true`.
    class OverlapNotElapsed < Error; end

    def initialize(tenant, purpose: 'catalog_index', overlap: OVERLAP, clock: -> { Time.current }, logger: nil)
      raise ArgumentError, 'tenant must be a saved Tenant' unless tenant.is_a?(Tenant) && tenant.persisted?
      raise ArgumentError, "unknown purpose #{purpose.inspect}" unless TenantSigningKey::PURPOSES.include?(purpose)

      @tenant = tenant
      @purpose = purpose
      @overlap = overlap
      @clock = clock
      @logger = logger
    end

    # The tenant's first key, created directly as `active`. Refused if any key exists.
    def generate!
      step do |keys|
        raise InvalidState, "#{label} already has a key; use stage_next!" if keys.any?

        build_key(status: 'active', activated_at: now, sequence: next_sequence(keys))
      end
    end

    # A new `pending` key: published in the manifest so it can be baked into pins before use, but
    # it signs nothing and is not trusted. Refused if one is already pending.
    def stage_next!
      step do |keys|
        raise InvalidState, "#{label} has no active key; generate! the first key first" unless in_status(keys, 'active')
        raise InvalidState, "#{label} already has a pending key" if in_status(keys, 'pending')

        build_key(status: 'pending', sequence: next_sequence(keys))
      end
    end

    # `pending` becomes `active`; the old `active` becomes `retiring` (it keeps signing through the
    # overlap). The new key INHERITS the old key's `last_signed_at`, so a reader's anti-rollback
    # memory never sees the index counter go backwards (doc section 5).
    # @return [TenantSigningKey] the newly active key
    def promote!
      step do |keys|
        pending = in_status(keys, 'pending') or raise InvalidState, "#{label} has no pending key; stage_next! first"
        active = in_status(keys, 'active') or raise InvalidState, "#{label} has no active key"
        raise InvalidState, "#{label} still has a retiring key; retire! it first" if in_status(keys, 'retiring')

        seq = next_sequence(keys)
        # Demote first: the partial unique index allows only one `active` at a time.
        active.update!(status: 'retiring', sequence: seq)
        pending.update!(status: 'active', activated_at: now, sequence: seq,
                        last_signed_at: [active.last_signed_at, pending.last_signed_at].compact.max)
        pending
      end
    end

    # `retiring` becomes `retired` and its private key is destroyed (it cannot sign again, even by
    # mistake). Refused until the overlap window (measured from the promotion) has elapsed, unless
    # `force: true`, which is logged. A forced retire right after `promote!` is the compromise
    # runbook's "no overlap" hard cut (doc section 7).
    def retire!(force: false)
      step do |keys|
        retiring = in_status(keys, 'retiring') or raise InvalidState, "#{label} has no retiring key"
        promoted_at = in_status(keys, 'active')&.activated_at
        window_ends = promoted_at && (promoted_at + @overlap)
        early = window_ends.nil? || now < window_ends
        if early && !force
          raise OverlapNotElapsed, "#{label}: the #{@overlap.inspect} overlap ends at #{window_ends&.utc&.iso8601}; " \
                                   'pass force: true to retire early'
        end

        log_forced_retire(retiring) if early
        retiring.update!(status: 'retired', private_key_pem: nil, retired_at: now, sequence: next_sequence(keys))
        retiring
      end
    end

    private

    def step
      TenantSigningKey.transaction do
        Tenant.lock.find(@tenant.id)
        keys = TenantSigningKey.for_tenant(@tenant, @purpose).order(:id).lock.to_a
        yield keys
      end
    rescue ActiveRecord::RecordNotUnique => e
      # Unreachable while the tenant-row lock holds; kept so the index can never leak a raw
      # database error to a caller.
      raise InvalidState, "#{label}: a concurrent key change won (#{e.class})"
    end

    def build_key(attrs)
      TenantSigningKey.create!(attrs.merge(tenant: @tenant, purpose: @purpose,
                                           private_key_pem: CatalogIndex::Ed25519.generate_pem))
    end

    def in_status(keys, status)
      keys.find { |k| k.status == status }
    end

    def next_sequence(keys)
      keys.map(&:sequence).max.to_i + 1
    end

    def now
      @clock.call
    end

    def label
      "tenant #{@tenant.tenant_id.inspect}"
    end

    def log_forced_retire(key)
      log = @logger || (defined?(Rails) && Rails.logger)
      log&.warn("[tenant-keys] FORCED early retire of #{label} key #{key.key_id} (#{@purpose}) " \
                'before the overlap window ended')
    end
  end
end
