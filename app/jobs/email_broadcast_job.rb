# frozen_string_literal: true

# Emails #2 and #4 (Task 12): a notice (errors / maintenance / per-app) or a
# campaign, to everyone who opted in to that kind — or only to the members of
# one app when `app_id` is given (campaigns are always platform-wide).
#
#   EmailBroadcastJob.perform_later(kind: 'notices', subject: '…', body: '…')
#   EmailBroadcastJob.perform_later(kind: 'notices', subject: '…', body: '…', app_id: app.id)
#   EmailBroadcastJob.perform_later(kind: 'campaigns', subject: '…', body: '…')
class EmailBroadcastJob < ApplicationJob
  KINDS = %w[notices campaigns].freeze

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(kind:, subject:, body:, app_id: nil)
    return unless EmailNotifications.enabled?

    raise ArgumentError, "unknown broadcast kind: #{kind}" unless KINDS.include?(kind.to_s)

    app = app_id.present? && kind.to_s == 'notices' ? App.find(app_id) : nil

    self.class.recipients(kind: kind, app_id: app&.id).find_each do |user|
      mail = if kind.to_s == 'campaigns'
               NotificationMailer.campaign(user, subject: subject, body: body)
             else
               NotificationMailer.notice(user, subject: subject, body: body, app: app)
             end
      mail.deliver_later
    end
  end

  # Also used by the rake tasks for dry runs.
  def self.recipients(kind:, app_id: nil)
    if app_id.present? && kind.to_s == 'notices'
      User.wanting_email_for_app(App.find(app_id), kind)
    else
      User.wanting_email(kind)
    end
  end
end
