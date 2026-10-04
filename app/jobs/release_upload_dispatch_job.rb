# frozen_string_literal: true

# Task 40i-a: after finalize moved an upload to `uploaded`, send it to the stage-1 workflow and record that.
#
#   uploaded (dispatched_at nil) -> uploaded (dispatched_at set)   the workflow_dispatch call succeeded
#   uploaded                     -> failed                         GitHub refused or CI is misconfigured; the
#                                                                  reason is in `error`
#
# Light: one HTTP call, no file touched. Every write is conditional on the row still being `uploaded` and not yet
# dispatched, so a stage-1 callback that beat this job, or the sweeper failing the row, is never overwritten.
# One attempt: a failed dispatch fails the upload with a reason and the owner uploads again (the staged object
# is kept until the sweeper or the bucket's lifecycle rule removes it).
#
# Not verified: no Ruby in the sandbox this was written in, and no call to GitHub.
class ReleaseUploadDispatchJob < ApplicationJob
  queue_as :default

  def perform(upload_id)
    upload = ReleaseUpload.find_by(id: upload_id)
    return unless upload&.state_uploaded? && upload.dispatched_at.nil?

    ReleaseUploadDispatcher.new(upload).call
    pending(upload).update_all(dispatched_at: Time.current, updated_at: Time.current)
  rescue ReleaseUploadDispatcher::DispatchError => e
    fail_upload(upload, e.message)
  rescue StandardError => e
    logger.error("[ReleaseUploadDispatchJob] upload #{upload_id}: #{e.full_message}")
    fail_upload(upload, "unexpected #{e.class}: #{e.message}") if upload
  end

  private

  def pending(upload)
    ReleaseUpload.where(id: upload.id, state: 'uploaded', dispatched_at: nil)
  end

  def fail_upload(upload, reason)
    pending(upload).update_all(state: 'failed', error: reason.to_s.truncate(1000), updated_at: Time.current)
  end
end
