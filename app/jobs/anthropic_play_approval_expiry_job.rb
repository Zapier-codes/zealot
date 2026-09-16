# frozen_string_literal: true

# Auto-expiry cron for task #11 (Play Store publish-approval workflow).
# A release targeting Play Store needs explicit admin approval within 48h
# of being requested (Release#request_play_approval!); if nobody acts in
# that window, this job flips it to `expired` so it drops out of the
# admin/play_approvals queue rather than sitting there stale forever.
#
# Batch-scan pattern deliberately, same shape as
# AnthropicMtprotoArchiveJob, rather than scheduling a per-release delayed
# job at request time — one cheap periodic scan is simpler to reason about
# than N scheduled jobs that would each need to be found and cancelled if
# a release is approved/rejected before its timer fires.
#
# Expiry only ever affects Play Store publish eligibility (task #7, still
# not implemented) — it never touches file storage, channel visibility, or
# our own internal distribution. A release stays downloadable through
# Zealot itself regardless of this status, before or after expiry.
class AnthropicPlayApprovalExpiryJob < ApplicationJob
  queue_as :schedule

  def perform
    Release.play_approval_overdue.find_each do |release|
      release.expire_play_approval!
    rescue => e
      logger.error("[AnthropicPlayApprovalExpiryJob] failed for release #{release.id}: #{e.message}")
    end
  end
end
