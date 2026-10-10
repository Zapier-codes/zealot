# frozen_string_literal: true

module Play
  # Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rule 3): the daily canary. It runs one
  # fixed read (a stable public app) against *each* configured backend directly — it is what proves a
  # backend usable, so it must not go through the adapter's own "usable?" gate — and records the outcome
  # in `play_source_states`. When a backend fails, its state becomes `degraded` and the adapter stops
  # offering it, which is how the UI hides the Play panel on the day Google changes the interface.
  #
  # It never raises: a backend that is down, misconfigured, or whose command is missing is exactly the
  # condition the canary exists to record. Running the whole thing twice in a day is harmless (upsert).
  class Canary
    Outcome = Struct.new(:backend, :ok, :error, keyword_init: true)

    def self.run(**kwargs) = new(**kwargs).run

    def initialize(env: ENV, config: nil, states: PlaySourceState, runner_class: BackendRunner,
                   package: nil, now: Time.current)
      @env = env
      @config = config || Rails.configuration.x.play_catalog
      @states = states
      @runner_class = runner_class
      @package = package || @config.canary_package
      @now = now
    end

    # @return [Array<Outcome>] one per configured backend
    def run
      commands.map { |name, command| check(name, command) }
    end

    private

    def commands
      {
        'gplayapi'     => @config.gplayapi_command,
        'playstoreapi' => @config.playstoreapi_command,
      }.reject { |_name, command| command.to_s.strip.empty? }
    end

    def check(name, command)
      run = @runner_class.new(command).call(@package)
      panel = run.ok ? PanelNormalizer.call(run.raw, package: @package) : nil

      if panel
        @states.record!(name, ok: true, now: @now)
        Outcome.new(backend: name, ok: true)
      else
        error = run.error.to_s.strip
        error = 'no usable detail returned' if error.empty?
        @states.record!(name, ok: false, error: error, now: @now)
        Outcome.new(backend: name, ok: false, error: error)
      end
    rescue StandardError => e
      # A broken state table must not turn a canary run into a crash; log and report the miss.
      Rails.logger.warn("[Play::Canary] #{name} failed: #{e.message}") if defined?(Rails)
      Outcome.new(backend: name, ok: false, error: e.message)
    end
  end
end
