# frozen_string_literal: true

# Task 40b: sends one release to the storage repo's compile workflow and records where it got to.
#
#   nil / failed -> queued      `enqueue_for` (this slice: called by hand; the upload hook is 40d)
#   queued       -> dispatched  the workflow_dispatch call succeeded
#   queued       -> failed      the file is not in storage, CI is off or misconfigured, or GitHub refused;
#                               the reason is in `ci_compile_error`
#
# Light on purpose: no compile, no signing, no bundletool, nothing heavy on this instance. The one
# non-trivial step is making sure the AAB is in storage first (the workflow downloads it from there):
# `ReleaseFileMirrorJob` copies it if it is still on local disk, and if it is neither stored nor on disk the
# release fails with that reason instead of dispatching a run that could only fail.
#
# The state writes are conditional (`WHERE ci_compile_state = 'queued'`), so a result callback that arrives
# before this job records `dispatched` (Api::CiCompileController accepts a result from `queued`) is never
# overwritten, and a release that is already `done` is never moved back.
#
# Not verified: no Ruby in the sandbox this was written in, and no call to GitHub.
class CiCompileDispatchJob < ApplicationJob
  queue_as :default

  # States a release may be (re)sent from: never sent, or a previous attempt failed.
  SENDABLE = [nil, 'failed'].freeze

  # Marks the release `queued` and enqueues the job.
  #
  # @return [Boolean] false (and nothing changes) when CI is off, the release is not an AAB, or it is
  #   already queued, dispatched or done
  def self.enqueue_for(release)
    return false unless CiCompileDispatcher.enabled? && aab?(release) && SENDABLE.include?(release.ci_compile_state)

    release.update_columns(ci_compile_state: 'queued', ci_compile_error: nil, ci_compile_finished_at: nil)
    perform_later(release.id)
    true
  end

  def self.aab?(release)
    [release.file&.path, release.file_storage_key].any? { |name| name.to_s.end_with?('.aab') }
  end

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release&.ci_compile_queued?

    unless CiCompileDispatcher.enabled?
      return fail_release(release, 'CI_COMPILE_ENABLED is not "true", so the release was not sent to CI')
    end

    ensure_stored(release)
    CiCompileDispatcher.new(release).call
    Release.where(id: release.id, ci_compile_state: 'queued').update_all(ci_compile_state: 'dispatched')
  rescue CiCompileDispatcher::DispatchError => e
    fail_release(release, e.message)
  rescue StandardError => e
    logger.error("[CiCompileDispatchJob] release #{release_id}: #{e.full_message}")
    fail_release(release, "unexpected #{e.class}: #{e.message}") if release
  end

  private

  # The mirror skips whatever is already stored and logs its own errors; what matters is the key afterwards.
  def ensure_stored(release)
    ReleaseFileMirrorJob.perform_now(release.id) if release.file_storage_key.blank?
    release.reload
  rescue StandardError => e
    logger.error("[CiCompileDispatchJob] release #{release.id}: mirror before dispatch failed: #{e.message}")
  end

  def fail_release(release, reason)
    Release.where(id: release.id, ci_compile_state: 'queued')
           .update_all(ci_compile_state: 'failed', ci_compile_error: reason.to_s.truncate(1000),
                       ci_compile_finished_at: Time.current)
  end
end
