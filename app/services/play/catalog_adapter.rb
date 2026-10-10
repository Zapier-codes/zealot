# frozen_string_literal: true

module Play
  # Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1): the ONE adapter through which the
  # reverse-engineered Play clients are reached. Nothing else in Zealot, Appstore or D-Store imports either
  # library, and this class itself only knows about *commands* — the vendored Kotlin `GPlayApi` and the
  # vendored Python `playstoreapi` sit behind them (rule 1: two implementations so one can fail over).
  #
  # The order of operations is exactly §1.1, and every path degrades to a hidden panel rather than an error:
  #
  #   1. off unless `ENABLE_PLAY_CATALOG` (rule 6)                        -> `disabled`
  #   2. a fresh cache hit (rule 5)                                        -> served from cache
  #   3. try each *usable* backend in turn (a backend is usable only if  -> `ok`
  #      its canary last passed; rule 3), fail over on any miss
  #   4. on total miss, serve a stale cache entry if one exists           -> `stale`
  #   5. otherwise                                                         -> `unavailable`
  #
  # `result` is a small value object: `panel` is the labelled hash (or nil), `status` is one of
  # `ok`/`stale`/`disabled`/`unavailable`, and `state` is the backend that answered (or nil). The caller
  # shows the panel only when `available?`, i.e. `ok` or `stale` — the "never the only path" rule, since
  # the catalogue itself is always shown regardless.
  class CatalogAdapter
    Result = Struct.new(:panel, :status, :backend, :error, keyword_init: true) do
      def available? = %w[ok stale].include?(status)
    end

    CACHE_PREFIX = 'play_panel'
    # How long a stale entry may stand in after every backend failed. A labelled panel with an old
    # timestamp is more honest than an empty one, but it must not be served forever.
    STALE_MAX_AGE = (ENV['PLAY_STALE_MAX_AGE_HOURS'] || 168).to_i.hours

    def self.call(package, **kwargs) = new(**kwargs).call(package)

    def initialize(env: ENV, config: nil, states: PlaySourceState, cache: PlayCatalogCache,
                   runner_class: BackendRunner, now: Time.current)
      @env = env
      @config = config || Rails.configuration.x.play_catalog
      @states = states
      @cache = cache
      @runner_class = runner_class
      @now = now
    end

    def call(package)
      pkg = package.to_s.strip
      return Result.new(status: 'unavailable', error: 'no package') if pkg.empty?
      return Result.new(status: 'disabled') unless enabled?

      if (fresh = @cache.read(cache_key(pkg), now: @now))
        return result_from_cache(fresh, status: 'ok')
      end

      errors = []
      backend_commands.each do |name, command|
        next unless backend_usable?(name)

        run = @runner_class.new(command).call(pkg)
        next errors << "#{name}: #{run.error}" unless run.ok

        panel = PanelNormalizer.call(run.raw, package: pkg)
        next errors << "#{name}: nothing usable" unless panel

        @cache.write(cache_key(pkg), panel, now: @now)
        return Result.new(panel: panel, status: 'ok', backend: name)
      end

      if (stale = stale_cache_read(pkg))
        return result_from_cache(stale, status: 'stale', error: errors.join('; '))
      end

      joined = errors.join('; ')
      Result.new(status: 'unavailable', error: joined.empty? ? 'no usable backend' : joined)
    end

    private

    def enabled?
      !!@config.enabled
    end

    def cache_key(pkg)
      "#{CACHE_PREFIX}__#{pkg}"
    end

    def result_from_cache(entry, status:, error: nil)
      Result.new(panel: entry['data'], status: status, backend: 'cache', error: error)
    end

    def stale_cache_read(pkg)
      # `read` with a large max_age serves the entry only if it is younger than STALE_MAX_AGE.
      @cache.read(cache_key(pkg), max_age: STALE_MAX_AGE, now: @now)
    end

    # A backend with a configured command is a candidate; rule 3 says a candidate is only *usable* when
    # its canary last passed (and not too long ago). An unproven backend is skipped, never tried blind.
    def backend_commands
      {
        'gplayapi'     => @config.gplayapi_command,
        'playstoreapi' => @config.playstoreapi_command,
      }.reject { |_name, command| command.to_s.strip.empty? }
    end

    def backend_usable?(name)
      state = @states.find_by(backend: name)
      # With no state row at all (the canary has never run) the backend is not proven, so it is skipped.
      # This is the deliberate safe default: a fresh deployment must run its canary before the panel shows.
      !state.nil? && state.usable?(now: @now)
    rescue StandardError
      false
    end
  end
end
