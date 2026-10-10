# frozen_string_literal: true

require 'open3'
require 'json'
require 'shellwords'
require 'timeout'

module Play
  # Z-P25 (docs/PARITY-KANBAN.md; docs/UNOFFICIAL-ROUTES.md §1.1 rules 1 and 7): runs ONE backend, in its
  # own process, and returns its parsed JSON. This is the licence boundary: Aurora's `GPlayApi` is
  # GPL-3.0-or-later and Zealot is MIT, so the library is never linked into Rails — it lives behind a
  # command this class invokes. The command contract is deliberately tiny and stable, so either the
  # vendored Kotlin client or the vendored Python client can implement it without Zealot knowing which:
  #
  #   <command> <packageName>        -> one JSON object on stdout, exit 0, on success
  #   (any non-zero exit, timeout, non-JSON) -> a miss
  #
  # Every failure is a nil, never a raise: the adapter's job is to fail over to the other backend, then to
  # a stale cache (rule 5), then to nothing (rule 6). A backend that hangs is bounded by `timeout`.
  class BackendRunner
    Result = Struct.new(:ok, :raw, :error, keyword_init: true)

    DEFAULT_TIMEOUT = (ENV['PLAY_BACKEND_TIMEOUT_SECONDS'] || 20).to_i

    def initialize(command, timeout: DEFAULT_TIMEOUT)
      @command = command.to_s
      @timeout = timeout
    end

    # @param package [String] the Play package name to read
    # @return [Result] ok=true with `raw` (a Hash), or ok=false with `error`
    def call(package)
      return Result.new(ok: false, error: 'no command configured') if @command.strip.empty?

      stdout, stderr, status = Timeout.timeout(@timeout) do
        Open3.capture3(*Shellwords.split(@command), package.to_s)
      end
      unless status.success?
        return Result.new(ok: false, error: "exit #{status.exitstatus}: #{clip(stderr.to_s.strip)}")
      end

      parsed = JSON.parse(stdout)
      return Result.new(ok: false, error: 'backend returned no JSON object') unless parsed.is_a?(Hash)

      Result.new(ok: true, raw: parsed)
    rescue JSON::ParserError
      Result.new(ok: false, error: 'backend output was not JSON')
    rescue Errno::ENOENT
      Result.new(ok: false, error: 'backend command not found')
    rescue Timeout::Error
      Result.new(ok: false, error: "timed out after #{@timeout}s")
    rescue StandardError => e
      Result.new(ok: false, error: clip("#{e.class}: #{e.message}"))
    end

    private

    # Plain Ruby (no ActiveSupport dependency), so the runner is exercised directly off-Rails.
    def clip(text, limit = 300)
      s = text.to_s
      s.length > limit ? "#{s[0, limit]}…" : s
    end
  end
end
