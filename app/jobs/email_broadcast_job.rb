# frozen_string_literal: true

# Emails #2 and #4 (Task 12): a notice (errors / maintenance / per-app) or a
# campaign, to everyone who opted in to that kind — or only to the members of
# one app when `app_id` is given (campaigns are always platform-wide).
#
#   EmailBroadcastJob.perform_later(kind: 'notices', subject: '…', body: '…')
#   EmailBroadcastJob.perform_later(kind: 'notices', subject: '…', body: '…', app_id: app.id)
#   EmailBroadcastJob.perform_later(kind: 'campaigns', subject: '…', body: '…')
#   EmailBroadcastJob.perform_later(kind: 'notices', subject: '…', body: '…', app_id: app.id, admins_only: true)
#
# `admins_only` (Task 18) sends the notice to the admins instead of the app's
# members — for things only an admin can act on. `app_id` then only gives the
# email its "about your app" context.
class EmailBroadcastJob < ApplicationJob
  KINDS = %w[notices campaigns].freeze

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(kind:, subject:, body:, app_id: nil, admins_only: false)
    return unless EmailNotifications.enabled?

    raise ArgumentError, "unknown broadcast kind: #{kind}" unless KINDS.include?(kind.to_s)

    app = app_id.present? && kind.to_s == 'notices' ? App.find(app_id) : nil

    self.class.recipients(kind: kind, app_id: app&.id, admins_only: admins_only).find_each do |user|
      if kind.to_s == 'campaigns'
        EmailNotifications.deliver_campaign(user, subject: subject, body: body, broadcast_id: job_id)
      else
        EmailNotifications.deliver_notice(user, subject: subject, body: body, app: app, broadcast_id: job_id)
      end
    end
  end

  # Also used by the rake tasks for dry runs.
  def self.recipients(kind:, app_id: nil, admins_only: false)
    return User.wanting_email(kind).admin if admins_only && kind.to_s == 'notices'

    if app_id.present? && kind.to_s == 'notices'
      User.wanting_email_for_app(App.find(app_id), kind)
    else
      User.wanting_email(kind)
    end
  end
end
