# frozen_string_literal: true

# Task 40g-2: housekeeping for direct-to-storage uploads (`release_uploads`, Task 40 decided flow, gap H).
#
#   awaiting_bytes -> expired   the client never finalized inside the window plus the finalize grace
#   uploaded       -> failed    finalized, but nothing picked the file up within the limit
#
# For an `expired` row the staged object is deleted too (best effort: the bucket's lifecycle rule on `staging/`
# is the backstop, so a delete that fails is only logged). A `failed` row keeps its object for CI to retry.
# `processing` and `done` are never touched: a release exists for them and the CI callbacks own those states.
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

  def unclaimed_reason
    "The file was received but not processed within #{self.class.stale_after.in_minutes.round} minutes. Upload it again."
  end

  def delete_staged(upload)
    return unless ReleaseUploadStaging.configured?

    ReleaseUploadStaging.new.delete(upload)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    logger.warn("[ReleaseUploadSweeperJob] staged object for upload #{upload.id} not deleted: #{e.message}")
  end
end
