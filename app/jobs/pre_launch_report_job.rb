# frozen_string_literal: true

# Z-P12 (Play Console parity; docs/PARITY-KANBAN.md): runs the pre-launch report -- a headless-Android run of
# the release's build in CI, driven by redroid + `adb shell monkey` -- and records the verdict on the release.
#
# Same dispatch pattern as Task 40's CI compile: Zealot does not host a device, it asks the workflow repo to run
# `pre-launch-report.yml` (exit `PreLaunchReport::Dispatcher`), and the workflow calls back
# `POST /api/pre_launch_reports/:id` with the JSON payload. Enqueued when a release is created (like the
# automated review, Z-P2) so every upload is exercised without a person asking.
#
# On a successful dispatch it marks the report `running` (so a run that never reports back is visible, not
# silently `not_run`). A dispatch failure records `failed` with the reason. Off unless PRE_LAUNCH_REPO and
# PRE_LAUNCH_DISPATCH_TOKEN are set; with no dispatcher the release page shows no card.
#
# Written, NOT run against a real redroid/CI (no device in the writing sandbox); the pure half, the dispatcher
# and the callback are unit-tested with fakes. A real run is the operator's first proof.
class PreLaunchReportJob < ApplicationJob
  queue_as :default

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release
    return unless PreLaunchReport::Dispatcher.enabled?

    ::ReleaseChecks::PreLaunchRecorder.record!(release, status: 'running')
    PreLaunchReport::Dispatcher.new(release).call
  rescue PreLaunchReport::Dispatcher::DispatchError => e
    record_failure(release, e)
  rescue StandardError => e
    record_failure(release, e)
  end

  def self.enabled?
    PreLaunchReport::Dispatcher.enabled?
  end

  private

  def record_failure(release, error)
    return unless release

    ::ReleaseChecks::PreLaunchRecorder.record!(release, status: 'failed', error: "#{error.class}: #{error.message}")
  end
end
