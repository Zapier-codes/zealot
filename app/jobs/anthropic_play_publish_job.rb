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
class AnthropicPlayPublishJob < ApplicationJob
  queue_as :default

  def perform(release_id)
    release = Release.find_by(id: release_id)
    return unless release
    return unless release.play_store_target? && release.play_approval_approved?

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
end
