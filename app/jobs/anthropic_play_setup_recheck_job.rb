# frozen_string_literal: true

# Task 18: cron. Once a developer has done the manual Play Console step
# (the first bundle upload of a new app), nobody should have
# to come back and press anything: this re-checks, every few minutes, only
# the apps that still have an approved release waiting for Play setup
# (Release#play_publish_waiting_for_setup). Idle apps are never polled, so
# Google's API isn't hit on a schedule for no reason. A ready result makes
# AnthropicPlayPreflightJob resume the waiting releases.
class AnthropicPlaySetupRecheckJob < ApplicationJob
  queue_as :schedule

  def perform
    app_ids = Release.play_publish_waiting_for_setup
                     .joins(channel: :scheme)
                     .reorder(nil)
                     .distinct
                     .pluck('schemes.app_id')

    app_ids.each do |app_id|
      AnthropicPlayPreflightJob.perform_later(app_id)
    rescue => e
      logger.error("[AnthropicPlaySetupRecheckJob] failed to enqueue app #{app_id}: #{e.message}")
    end
  end
end
