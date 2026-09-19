# frozen_string_literal: true

# Automated platform emails (Task 12). Always sent with `deliver_later` (GoodJob)
# to one recipient at a time, in the recipient's own locale, and every one of
# them links to that user's email-preferences page.
#
#   release_deployed — a new build of an app the user collaborates on
#   notice           — errors / maintenance / per-app notices
#   campaign         — platform announcements and branding campaigns
#
# Payment receipts are not here yet: there is no payment/invoice data model.
class NotificationMailer < ApplicationMailer
  layout 'notification_mailer'

  def release_deployed(release, user)
    @release = release
    @app = release.app
    @version = release.release_version.to_s
    @version += " (#{release.build_version})" if release.build_version.present?
    @changelog_lines = changelog_lines(release)

    localized_mail(user, :deploys, app: release.app_name, version: @version)
  end

  # `subject` and `body` are supplied by the caller (already written for the
  # audience). `app` is set for a notice about one specific app.
  def notice(user, subject:, body:, app: nil)
    @body = body
    @app = app

    localized_mail(user, :notices, subject: subject)
  end

  def campaign(user, subject:, body:)
    @body = body

    localized_mail(user, :campaigns, subject: subject)
  end

  private

  # `changelog` is a jsonb array of { "message" => "..." } hashes (or blank).
  def changelog_lines(release)
    Array(release.changelog).filter_map do |entry|
      line = entry.is_a?(Hash) ? (entry['message'] || entry[:message]) : entry
      line.to_s.strip.presence
    end.first(20)
  end

  def localized_mail(user, kind, subject: nil, **subject_args)
    @user = user
    @kind = kind
    @preferences_url = email_preferences_url(user.email_preferences_token)
    headers['List-Unsubscribe'] = "<#{@preferences_url}>" if kind == :campaigns

    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail(to: user.email, subject: subject || t('.subject', **subject_args))
    end
  end
end
