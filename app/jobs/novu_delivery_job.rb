# frozen_string_literal: true

# Task 16: hands ONE email to Novu (one workflow trigger for one subscriber).
# Fanning out to recipients stays in ReleaseDeployNotificationJob /
# EmailBroadcastJob, so a Novu hiccup only retries that one recipient.
#
# `kind` (deploys / notices / campaigns) is re-checked here: the user may have
# opted out, or been locked, between enqueue and delivery.
class NovuDeliveryJob < ApplicationJob
  queue_as :default

  # GoodJob is configured with retry_on_unhandled_error = false, so retries
  # have to be declared explicitly.
  retry_on NovuClient::TemporaryError, wait: :polynomially_longer, attempts: 6

  discard_on ActiveRecord::RecordNotFound
  discard_on NovuClient::PermanentError do |job, error|
    Rails.error.report(error, handled: true, severity: :error,
                              context: { job: job.class.name, workflow: job.arguments.first })
    GoodJob.logger.error("[novu] giving up on #{job.arguments.first}: #{error.message}")
  end

  def perform(workflow_id, user_id, kind, payload, transaction_id)
    user = User.find(user_id)
    return unless user.locked_at.nil? && user.wants_email?(kind)

    NovuClient.trigger(
      workflow_id: workflow_id,
      to: EmailNotifications.novu_subscriber(user),
      payload: payload,
      transaction_id: transaction_id
    )
  end
end
