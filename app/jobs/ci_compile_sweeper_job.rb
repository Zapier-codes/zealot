# frozen_string_literal: true

# Task 40g (gap H): a CI compile that never reports back must not sit `queued` or `dispatched` forever.
#
#   queued     -> failed   the dispatch job never ran (lost job, worker down) within the limit
#   dispatched -> failed   the workflow run died, was cancelled or never started, so no callback came
#
# The reason is written to `ci_compile_error`, which is what the console shows. `failed` is the state
# `CiCompileDispatchJob.enqueue_for` re-sends from, so recovery is one re-send; this job never re-dispatches
# on its own (a run that is merely slow and then finishes would otherwise compile the same release twice).
# A callback that arrives after the sweep is answered 409 by Api::CiCompileController (state is `failed`).
#
# Limit: CI_COMPILE_STALE_AFTER_MINUTES, default 90 (the workflow's own timeout is 45 minutes, the rest is
# runner queue time). Unset, empty or non-positive falls back to the default.
#
# A release that is in flight but has no `ci_compile_state_at` (dispatched before that column existed) is
# stamped with the current time first and judged from there, so adding the column fails nothing early.
# Every write is conditional on the state still being the one that was read, so a callback that lands
# between the read and the write wins.
#
# Cheap by design: two indexed-state queries and a few single-row updates, no GitHub call, no file access.
#
# Not verified: no Ruby in the sandbox this was written in, and nothing was run.
class CiCompileSweeperJob < ApplicationJob
  queue_as :schedule

  IN_FLIGHT = %w[queued dispatched].freeze
  DEFAULT_STALE_AFTER = 90.minutes

  def self.stale_after
    minutes = ENV['CI_COMPILE_STALE_AFTER_MINUTES'].to_i
    minutes.positive? ? minutes.minutes : DEFAULT_STALE_AFTER
  end

  def perform
    now = Time.current
    Release.where(ci_compile_state: IN_FLIGHT, ci_compile_state_at: nil).update_all(ci_compile_state_at: now)

    cutoff = now - self.class.stale_after
    Release.where(ci_compile_state: IN_FLIGHT).where(ci_compile_state_at: ...cutoff).find_each do |release|
      sweep(release, cutoff)
    rescue StandardError => e
      logger.error("[CiCompileSweeperJob] release #{release.id}: #{e.message}")
    end
  end

  private

  def sweep(release, cutoff)
    was = release.ci_compile_state
    changed = Release.where(id: release.id, ci_compile_state: was)
                     .where(ci_compile_state_at: ...cutoff)
                     .update_all(ci_compile_state: 'failed', ci_compile_error: reason_for(was),
                                 ci_compile_finished_at: Time.current)
    return unless changed.positive?

    logger.warn("[CiCompileSweeperJob] release #{release.id} was #{was} with no result; marked failed")
  end

  def reason_for(was)
    minutes = self.class.stale_after.in_minutes.round
    if was == 'queued'
      "The dispatch job did not run within #{minutes} minutes of being queued. Send the release to CI again."
    else
      "CI did not report back within #{minutes} minutes of the dispatch. Check the compile-aab run in the " \
        'storage repo (it may have died or never started), then send the release to CI again.'
    end
  end
end
