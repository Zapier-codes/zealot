# frozen_string_literal: true

# Z-P2/Z-P4 (Play Console parity): runs the automated review on a release. Enqueued when a release is created
# (Z-P2's "replace the human queue" principle: every upload is checked without a person asking). It:
#
#   1. marks the review `running`,
#   2. has MobSF scan the APK for third-party SDKs (Z-P4) when the scanner is configured -- a scanner that is
#      down degrades to "no trackers found", never fails the review,
#   3. runs the pure static checks (`ReleaseChecks::AutomatedReview`) and records the verdict on the release.
#
# It never blocks or unpublishes anything: the verdict is information the Console (Z-P3) and a person act on.
class AutomatedReviewJob < ApplicationJob
  queue_as :default

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release

    review = ReleaseChecks::AutomatedReview.new(release, trackers: scanned_trackers(release))
    review.record!(status: 'running') # status first, so a stuck scan is visible rather than silent
    review.record!(result: review.call)
  rescue StandardError => e
    # A runner that breaks must not look like a pass: record `failed` with the reason, leave the verdict nil.
    release&.update_columns(automated_review_status: 'failed', automated_reviewed_at: Time.current,
                            automated_review_reasons: [{ 'code' => 'runner_error', 'severity' => 'flag',
                                                         'message' => "#{e.class}: #{e.message}" }])
  end

  private

  # The APK bytes for MobSF, from the same storage the release already uses. Best-effort: any failure to read
  # the file (or a scanner that is not configured) yields no trackers, not a broken review.
  def scanned_trackers(release)
    return [] unless ReleaseChecks::MobsfClient.configured?

    bytes = release_file_bytes(release)
    return [] if bytes.blank?

    ReleaseChecks::MobsfClient.new.scan(bytes)
  rescue StandardError
    []
  end

  def release_file_bytes(release)
    ReleaseStorage.new(release).with_local_file { |path| File.binread(path) }
  rescue StandardError
    nil
  end
end
