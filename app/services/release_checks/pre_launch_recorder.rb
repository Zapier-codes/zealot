# frozen_string_literal: true

module ReleaseChecks
  # Z-P12 (Play Console parity; docs/PARITY-KANBAN.md): records the pre-launch report onto a release. The
  # runner (a separate redroid program, `PreLaunchReport::Client`) produces a raw JSON payload; the pure
  # `PreLaunchReport.from_payload` turns it into a verdict and findings; this writes them to the release's
  # `pre_launch_*` columns so the Console (the release page card) can show them.
  #
  # `status:` lets the job mark `running` before a run that takes minutes, and `failed` when the runner broke.
  # A runner that fails writes `failed` with the reason and leaves the verdict nil -- never a pass.
  #
  # A separate class from the pure `PreLaunchReport` (same name, different namespace): this is the writer, the
  # pure module is the reader, the same split `ReleaseChecks::AutomatedReview` uses.
  class PreLaunchRecorder
    def self.record!(release, status:, payload: nil, error: nil)
      findings = []
      verdict = nil
      summary = nil

      if payload
        result = ::PreLaunchReport.from_payload(payload)
        verdict = result.verdict
        findings = result.findings.map { |f| { 'code' => f.code, 'severity' => f.severity, 'message' => f.message } }
        summary = result.summary
      elsif error
        findings = [{ 'code' => 'runner_error', 'severity' => 'flag', 'message' => error.to_s }]
      end

      release.update_columns(
        pre_launch_status: status,
        pre_launch_verdict: verdict,
        pre_launch_summary: summary,
        pre_launch_findings: findings,
        pre_launch_run_at: Time.current
      )
    end
  end
end
