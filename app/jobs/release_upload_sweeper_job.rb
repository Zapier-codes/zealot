# frozen_string_literal: true

# Task 40g-2: housekeeping for direct-to-storage uploads (`release_uploads`, Task 40 decided flow, gap H).
#
#   awaiting_bytes -> expired   the client never finalized inside the window plus the finalize grace
#   uploaded       -> failed    finalized, but nothing picked the file up within the limit
#   processing     -> failed    (Task 40i-c) stage 1 made the release but stage 2 never reported back
#
# For an `expired` row the staged object is deleted too, and the half-sent multipart upload of a row opened in
# parts (Task 40s-c) is aborted (best effort: the bucket's lifecycle rule on `staging/`
# is the backstop, so a delete that fails is only logged). A `failed` row keeps its object for CI to retry.
# `done` is never touched. A `processing` row has a release (held, with no file); when stage 2 does not report
# within the same limit, counted from the stage-1 report, the row is failed and the reason is written on the held
# release's `ci_compile_error`, exactly as a `failed` report from CI would. The release stays held: it has no
# file, so it must not become available. The owner deletes it and uploads again.
#
# Why GRACE: finalize accepts a call until `expires_at + ReleaseUploadFinalizer::GRACE`, so the sweeper waits
# the same time; a PUT that started inside the window can finish after it.
#
# Limit for `uploaded`: RELEASE_UPLOAD_STALE_AFTER_MINUTES, default 90 (CI's own timeout is 45 minutes).
# Unset, empty, zero, negative or non-numeric falls back to the default. Until slice 40i-a exists nothing picks
# an `uploaded` row up, so with direct upload switched on such rows fail after the limit with a reason that says so.
#
# Every write is conditional on the state and time still being what was read, so a finalize or a CI callback
# that lands in between wins. Database reads and single-row updates; the only network call is the delete.
#
# Not verified: no Ruby in the sandbox this was written in, and nothing was run.
class ReleaseUploadSweeperJob < ApplicationJob
  queue_as :schedule

  DEFAULT_STALE_AFTER = 90.minutes

  def self.stale_after
    minutes = ENV['RELEASE_UPLOAD_STALE_AFTER_MINUTES'].to_i
    minutes.positive? ? minutes.minutes : DEFAULT_STALE_AFTER
  end

  def perform
    now = Time.current
    expire_unfinished(now)
    fail_unclaimed(now)
    fail_unfinished(now)
  end

  private

  def expire_unfinished(now)
    cutoff = now - ReleaseUploadFinalizer::GRACE
    ReleaseUpload.stale_awaiting(cutoff).find_each do |upload|
      changed = ReleaseUpload.where(id: upload.id, state: 'awaiting_bytes').where(expires_at: ...cutoff)
                             .update_all(state: 'expired', updated_at: Time.current,
                                         error: 'The file was not finalized within the upload window.')
      next unless changed.positive?

      logger.info("[ReleaseUploadSweeperJob] upload #{upload.id} expired")
      delete_staged(upload)
    rescue StandardError => e
      logger.error("[ReleaseUploadSweeperJob] upload #{upload.id}: #{e.message}")
    end
  end

  def fail_unclaimed(now)
    cutoff = now - self.class.stale_after
    ReleaseUpload.where(state: 'uploaded', uploaded_at: ...cutoff).find_each do |upload|
      changed = ReleaseUpload.where(id: upload.id, state: 'uploaded').where(uploaded_at: ...cutoff)
                             .update_all(state: 'failed', updated_at: Time.current, error: unclaimed_reason)
      logger.warn("[ReleaseUploadSweeperJob] upload #{upload.id} was never processed; marked failed") if changed.positive?
    rescue StandardError => e
      logger.error("[ReleaseUploadSweeperJob] upload #{upload.id}: #{e.message}")
    end
  end

  # Task 40i-c
  def fail_unfinished(now)
    cutoff = now - self.class.stale_after
    ReleaseUpload.where(state: 'processing', stage1_at: ...cutoff).find_each do |upload|
      changed = ReleaseUpload.where(id: upload.id, state: 'processing').where(stage1_at: ...cutoff)
                             .update_all(state: 'failed', updated_at: Time.current, error: unfinished_reason)
      next unless changed.positive?

      fail_held_release(upload)
      logger.warn("[ReleaseUploadSweeperJob] upload #{upload.id} never finished stage 2; marked failed")
    rescue StandardError => e
      logger.error("[ReleaseUploadSweeperJob] upload #{upload.id}: #{e.message}")
    end
  end

  def fail_held_release(upload)
    return if upload.release_id.blank?

    Release.where(id: upload.release_id)
           .update_all(ci_compile_state: 'failed', ci_compile_error: unfinished_reason,
                       ci_compile_finished_at: Time.current)
  end

  def unfinished_reason
    "CI did not finish preparing the files within #{self.class.stale_after.in_minutes.round} minutes. " \
      'Delete this release and upload it again.'
  end

  def unclaimed_reason
    "The file was received but not processed within #{self.class.stale_after.in_minutes.round} minutes. Upload it again."
  end

  # Task 40s-c: a multipart row's half-sent upload is aborted first (R2 keeps the parts, and bills them, until it
  # is; the bucket's one-day rule is the backstop), then the object is deleted as for any row.
  def delete_staged(upload)
    return unless ReleaseUploadStaging.configured?

    staging = ReleaseUploadStaging.new
    staging.abort_multipart(upload) if upload.multipart?
    staging.delete(upload)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    logger.warn("[ReleaseUploadSweeperJob] staged object for upload #{upload.id} not deleted: #{e.message}")
  end
end
