# frozen_string_literal: true

# Task 18: checks one App's Play-side setup (see
# Anthropic::PlayPreflightService), records the result on the App so the
# missing manual step is visible, and — the automation — resumes any
# releases that were waiting for that setup the moment it turns out to be
# done. Enqueued when an App's Play applicationId is set/adopted, and by
# AnthropicPlaySetupRecheckJob for apps that still have releases waiting.
class AnthropicPlayPreflightJob < ApplicationJob
  queue_as :default

  def perform(app_id)
    app = App.find_by(id: app_id)
    return unless app

    result = Anthropic::PlayPreflightService.new.check(app.play_package_name)
    app.record_play_setup!(result)
    app.resume_waiting_play_publishes! if result.ready?
  end
end
