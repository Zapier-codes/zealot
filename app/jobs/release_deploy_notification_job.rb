# frozen_string_literal: true

# Email #1 (Task 12): a new build of an app was published. Fans out one email
# per opted-in member of the app (SMTP mailer or Novu trigger, see
# EmailNotifications), so a bad address or provider hiccup only retries that
# one mail.
class ReleaseDeployNotificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(release_id)
    return unless EmailNotifications.enabled?

    release = Release.find(release_id)
    User.wanting_email_for_app(release.app, :deploys).find_each do |user|
      EmailNotifications.deliver_release_deployed(release, user)
    end
  end
end
