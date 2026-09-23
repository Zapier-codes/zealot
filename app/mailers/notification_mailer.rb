# frozen_string_literal: true

# Automated platform emails (Task 12). Always sent with `deliver_later` (GoodJob)
# to one recipient at a time, in the recipient's own locale, and every one of
# them links to that user's email-preferences page.
#
#   release_deployed — a new build of an app the user collaborates on
#   notice           — errors / maintenance / per-app notices
#   campaign         — platform announcements and branding campaigns
#   invite           — admin created an account with no password; set one
#
# Payment receipts are not here yet: there is no payment/invoice data model.
class NotificationMailer < ApplicationMailer
  layout 'notification_mailer'

  def release_deployed(release, user)
    @release = release
    @app = release.app
    @version = release.release_version.to_s
    @version += " (#{release.build_version})" if release.build_version.present?
    @changelog_lines = EmailNotifications.changelog_lines(release)

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

  # Sent once by Admin::UsersController#create when an admin adds a user
  # without setting a password. Deliberately not routed through
  # `localized_mail` — that method's footer assumes one of
  # EmailPreferences::KINDS ("you opted in to..."), which doesn't fit an
  # account someone else just created.
  def invite(user, set_password_url)
    @user = user
    @kind = :invite
    @set_password_url = set_password_url
    @preferences_url = email_preferences_url(user.email_preferences_token)

    I18n.with_locale(user.locale.presence || I18n.default_locale) do
      mail(to: user.email, subject: t('.subject', site: Setting.site_title))
    end
  end

  private

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
