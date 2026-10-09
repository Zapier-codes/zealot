# frozen_string_literal: true

# Task 46d: a release that has just become available and installable replaces the older releases of its channel.
# Zealot keeps ONE version per app (the operator's rule: an uploaded new version supersedes the old one, nothing
# is kept for roll back), so this runs by itself instead of waiting for someone to call
# `POST /api/releases/:id/supersede_previous` (Task 46c, which stays for manual use).
#
# Enqueued by `Release#enqueue_supersede_previous` after a commit that created an available release or changed
# its status, CI result or stored file key. All the safety is in `ReleaseSuperseder`: it removes nothing until the
# named release is `available` and really installable, so a held release, a compile still running or a failed
# compile removes nothing here either, and a later save that makes it installable enqueues this job again.
# A release with a HIGHER id is never touched, and another channel is never touched.
#
# This deletes releases and their stored files for good. Switch it off with `AUTO_SUPERSEDE=false` (also `0`,
# `off` or `no`); the default is on.
#
# Never retried: a refusal is the normal answer while a release is not ready yet, and a failure to remove one
# older release is logged and left for the next run, because each older release is removed on its own.
#
# Written, NOT run (no Rails or database in the sandbox that wrote it); see spec/jobs/release_supersede_job_spec.rb.
class ReleaseSupersedeJob < ApplicationJob
  queue_as :default

  DISABLED_VALUES = %w[false 0 off no].freeze

  def self.enabled?
    !DISABLED_VALUES.include?(ENV.fetch('AUTO_SUPERSEDE', 'true').to_s.strip.downcase)
  end

  def perform(release_id)
    return unless self.class.enabled?

    release = Release.find_by(id: release_id)
    return if release.nil?

    result = ReleaseSuperseder.new(release).call
    log_result(release, result)
  rescue ReleaseSuperseder::Refused => e
    logger.info("[ReleaseSupersedeJob] release #{release_id}: nothing removed (#{e.message})")
  end

  private

  def log_result(release, result)
    return if result.removed.empty? && result.failed.empty?

    logger.info("[ReleaseSupersedeJob] release #{release.id} kept; removed #{result.removed.map(&:id).inspect}")
    return if result.failed.empty?

    logger.warn("[ReleaseSupersedeJob] release #{release.id}: could not remove #{result.failed.map(&:id).inspect}")
  end
end
