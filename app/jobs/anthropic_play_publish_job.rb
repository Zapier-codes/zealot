# frozen_string_literal: true

# Task #7: runs after an admin approves a release for Play Store (task
# #11's Release#approve_play_publish!). This is the job that actually
# calls Anthropic::PlayPublishService — everything before this point
# (signing pipeline, approval queue) was bookkeeping/groundwork.
#
# Deliberately NOT retried automatically on failure (no `retry_on` here):
# a failed Play publish needs a human to look at play_publish_error and
# decide whether to fix something (missing credentials, wrong track,
# rejected by Google for a policy reason) and manually re-trigger, rather
# than silently hammering Google's API on a schedule. Re-running is just
# calling this job again for the same release_id once whatever was wrong
# is fixed.
#
# Task 18: one class of problem is different — the Play Console step a
# human has to do by hand (the first bundle upload of a new app). Before signing/uploading anything this job now runs the cheap
# Anthropic::PlayPreflightService check; if the only thing missing is that
# first upload, the release is parked as `waiting_for_setup` (not `failed`) and
# AnthropicPlaySetupRecheckJob / AnthropicPlayPreflightJob re-run this job
# by themselves once Google says the app is ready.
class AnthropicPlayPublishJob < ApplicationJob
  queue_as :default

  # A `publishing` status older than this is treated as a crashed run and
  # may be retried; younger ones mean another run is still in flight.
  STALE_PUBLISHING_AFTER = 30.minutes

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release
    return unless release.play_store_target? && release.play_approval_approved?
    return if release.play_publish_published?
    return if release.play_publish_publishing? && release.updated_at > STALE_PUBLISHING_AFTER.ago

    return unless setup_ready?(release)

    release.update!(play_publish_status: :publishing, play_publish_error: nil)

    edit_id = Anthropic::PlayPublishService.new.publish!(release)

    release.update!(
      play_publish_status: :published,
      play_published_at: Time.current,
      play_edit_id: edit_id,
      play_publish_error: nil
    )
  rescue Anthropic::PlayPublishService::NotConfiguredError,
         Anthropic::PlayPublishService::PublishError => e
    logger.error("[AnthropicPlayPublishJob] failed for release #{release_id}: #{e.message}")
    release&.update!(play_publish_status: :failed, play_publish_error: e.message)
  rescue StandardError => e
    logger.error("[AnthropicPlayPublishJob] unexpected failure for release #{release_id}: #{e.full_message}")
    release&.update!(play_publish_status: :failed, play_publish_error: "[#{e.class}] #{e.message}")
  end

  private

  # Runs the preflight check and records it on the App. Returns true when
  # publishing can go ahead; otherwise parks/fails the release and returns
  # false.
  def setup_ready?(release)
    package_name = release.bundle_id.presence || release.app.play_package_name
    result = Anthropic::PlayPreflightService.new.check(package_name)
    release.app.record_play_setup!(result)
    return true if result.ready?

    status = result.waiting_for_setup? ? :waiting_for_setup : :failed
    release.update!(play_publish_status: status, play_publish_error: result.message)
    false
  end
end
