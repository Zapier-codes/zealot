# frozen_string_literal: true

module Zealot
  # Task 37b-ii-t2: the DB-backed, cached `registry` for `Zealot::TenantResolver` (wired in
  # `config/initializers/tenant_host.rb`). `#call` returns the tenants as plain, frozen
  # `TenantResolver::Ref` snapshots (`tenant_id`, `domains`) -- never ActiveRecord objects -- so
  # they are safe to hold in a process-local cache and share between threads.
  #
  #   * Cached per process for `ttl` seconds (`TENANT_REGISTRY_TTL`, default 30; 0 in the test
  #     env). A tenant edit is therefore visible in every process within one TTL; `.reset!`
  #     makes it visible immediately in the *current* process only.
  #   * FAILS CLOSED: any error reading the table (DB down, pool exhausted, or the `tenants`
  #     table missing because the deploy runs migrations at container start and the first
  #     request can precede them) yields NO tenants, which the resolver turns into the default
  #     tenant. That empty answer is cached for the much shorter `failure_ttl` so a broken
  #     database is not queried on every request, and a healthy one is picked up again quickly.
  #     Last-known-good tenants are deliberately NOT served after a failure.
  #   * One query at a time: a refresh happens under a mutex, so a burst of requests on an
  #     expired cache issues one query, not one per request.
  class TenantRegistry
    DEFAULT_TTL = 30
    FAILURE_TTL = 5
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    DEFAULT_SOURCE = -> { Tenant.order(:tenant_id).pluck(:tenant_id, :domains) }

    # The tenants and their expiry live in ONE frozen object that is swapped atomically, so a
    # lock-free reader can never see a list paired with the wrong (or a nil) expiry.
    Snapshot = Struct.new(:tenants, :expires_at)

    class << self
      def instance
        @instance ||= new
      end

      def call
        instance.call
      end

      def reset!
        instance.reset!
      end

      def default_ttl
        value = Float(ENV['TENANT_REGISTRY_TTL'], exception: false)
        return value if value && value >= 0

        defined?(Rails) && Rails.env.test? ? 0 : DEFAULT_TTL
      end
    end

    # `source` returns `[[tenant_id, domains], ...]`; `clock` returns monotonic seconds.
    def initialize(source: DEFAULT_SOURCE, ttl: self.class.default_ttl, failure_ttl: FAILURE_TTL,
                   clock: MONOTONIC, logger: nil)
      @source = source
      @ttl = ttl
      @failure_ttl = failure_ttl
      @clock = clock
      @logger = logger
      @mutex = Mutex.new
      @snapshot = nil
    end

    def call
      snap = @snapshot
      return snap.tenants if fresh?(snap)

      @mutex.synchronize do
        # Another thread may have refreshed while we waited for the lock.
        snap = @snapshot
        return snap.tenants if fresh?(snap)

        refresh
      end
    end

    def reset!
      @mutex.synchronize { @snapshot = nil }
    end

    private

    def refresh
      rows = @source.call
      store(rows.map { |id, domains| build_ref(id, domains) }.freeze, @ttl)
    rescue StandardError => e
      warn_failure(e)
      store([].freeze, @failure_ttl)
    end

    def fresh?(snap)
      !snap.nil? && @clock.call < snap.expires_at
    end

    def store(tenants, ttl)
      @snapshot = Snapshot.new(tenants, @clock.call + ttl).freeze
      tenants
    end

    def build_ref(tenant_id, domains)
      TenantResolver::Ref.new(tenant_id.to_s.freeze, Array(domains).map { |d| d.to_s.freeze }.freeze).freeze
    end

    def warn_failure(error)
      log = @logger || (defined?(Rails) && Rails.logger)
      log&.warn("[tenant-registry] read failed, resolving every host to the default tenant " \
                "for #{@failure_ttl}s: #{error.class}: #{error.message}")
    end
  end
end
