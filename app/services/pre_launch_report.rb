# frozen_string_literal: true

# Z-P12 (Play Console parity; docs/PARITY-KANBAN.md): the pre-launch report. Play installs an upload on a
# set of real/emulated devices, launches it, drives it for a while and reports crashes, ANRs, exceptions and
# startup problems *before* a person reviews the release. Zealot's equivalent has two halves, split the same
# way the automated review (Z-P2) is:
#
#   * the PURE policy here -- it turns a runner's raw device observations into a verdict (pass/flag/reject)
#     and the human reasons. No I/O, no Rails, fully testable.
#   * `PreLaunchReport::Client` -- calls the robot runner (redroid on a headless Android image, driven by
#     `adb shell monkey`, in CI) and returns the raw payload. The runner is a pinned, separate program behind
#     an adapter, exactly as `docs/UNOFFICIAL-ROUTES.md` frames it; nothing here contains a device.
#
# The verdict never blocks distribution, matching Z-P2: it is information the Console shows and a person acts
# on. A runner that is down degrades to "not run", never to a false pass.
#
# The duplicate runtime serif problem does NOT reach this app: this is plain Ruby.
module PreLaunchReport
  # Worst-first: the verdict is the worst severity any finding carries (Play shows one verdict, not a list).
  SEVERITIES = %w[pass flag reject].freeze

  STATUSES = %w[not_run running done failed].freeze

  Finding = Struct.new(:code, :severity, :message, keyword_init: true)

  Result = Struct.new(:verdict, :findings, :summary, keyword_init: true) do
    def pass?   = verdict == 'pass'
    def flag?   = verdict == 'flag'
    def reject? = verdict == 'reject'
  end

  # A crash on any device is a reject (Play treats a launch crash as a blocker); an ANR, a startup problem or
  # a non-fatal exception is a flag. Kept as named constants so the bar moves in one place.
  CRASH_SEVERITY = 'reject'
  ANR_SEVERITY = 'flag'
  EXCEPTION_SEVERITY = 'flag'
  STARTUP_SEVERITY = 'flag'

  module_function

  # The verdict from a list of findings: the worst severity present wins.
  def verdict_for(findings)
    severities = Array(findings).map { |f| f.respond_to?(:severity) ? f.severity.to_s : nil }
    return 'reject' if severities.include?('reject')
    return 'flag' if severities.include?('flag')

    'pass'
  end

  # Builds the Result from the runner's raw, JSON-decoded payload. The payload shape is deliberately simple
  # and tolerant, because the runner is a separate program: a missing or malformed section is treated as
  # "nothing observed there", never as a crash. Keys read (all optional):
  #   devices      -- [{name:, api_level:, abi:}] the devices the build ran on
  #   crashes      -- [{device:, message:}]  each one becomes a reject finding
  #   anrs         -- [{device:, message:}]  each one becomes a flag finding
  #   exceptions   -- [{device:, message:}]  each one becomes a flag finding
  #   startup      -- {ok: true/false, message: ""}  a false `ok` becomes a flag finding
  #   events       -- Integer, how many monkey events each device was driven for (goes in the summary)
  def from_payload(payload)
    data = payload.is_a?(Hash) ? payload : {}
    findings = []
    findings.concat(observations(data, 'crashes', 'device_crash', CRASH_SEVERITY, 'Crashed'))
    findings.concat(observations(data, 'anrs', 'device_anr', ANR_SEVERITY, 'Stopped responding (ANR)'))
    findings.concat(observations(data, 'exceptions', 'device_exception', EXCEPTION_SEVERITY, 'Raised an exception'))
    startup = startup_finding(data['startup'])
    findings << startup if startup

    Result.new(verdict: verdict_for(findings), findings: findings, summary: summary_for(data, findings))
  end

  # A short human sentence for the Console card, e.g. "2 devices, 2000 events each: 1 reject, 1 flag".
  def summary_for(payload, findings = nil)
    devices = Array(payload.is_a?(Hash) ? payload['devices'] : nil)
    events = payload.is_a?(Hash) ? payload['events'] : nil
    findings ||= from_payload(payload).findings

    parts = []
    parts << "#{devices.size} #{devices.size == 1 ? 'device' : 'devices'}" if devices.any?
    parts << "#{events} events each" if events.to_i.positive?
    counts = findings.group_by(&:severity).transform_values(&:size)
    if counts.any?
      parts << counts.map { |severity, n| "#{n} #{severity}" }.sort.join(', ')
    else
      parts << 'no problems found'
    end
    parts.join(', ')
  end

  def observations(data, key, code, severity, verb)
    # Only an array is an observation list; a string or hash where a list is expected is malformed and is
    # treated as "nothing observed here" (the same rule as a missing section), so a bad payload cannot invent
    # a crash that did not happen.
    return [] unless data[key].is_a?(Array)

    data[key].filter_map do |item|
      message = item.is_a?(Hash) ? (item['message'] || item['reason'] || item['type']) : item
      device = item.is_a?(Hash) ? item['device'] : nil
      next if blank_text?(message) && blank_text?(device)

      text = [verb, (!blank_text?(device) ? "on #{device}" : nil), (!blank_text?(message) ? message : nil)].compact.join(' ')
      Finding.new(code: code, severity: severity, message: text)
    end
  end

  def startup_finding(startup)
    return nil unless startup.is_a?(Hash)
    return nil unless startup.key?('ok') && startup['ok'] != true

    message = startup['message'].to_s.strip
    text = ['Did not start cleanly', (!message.empty? ? message : nil)].compact.join(': ')
    Finding.new(code: 'startup_failure', severity: STARTUP_SEVERITY, message: text)
  end

  # Plain-Ruby equivalent of ActiveSupport's `blank?` for the strings read out of the runner's payload, so the
  # pure half needs no ActiveSupport (and stays loadable in a plain-Ruby test harness).
  def blank_text?(value)
    value.nil? || value.to_s.strip.empty?
  end
end
