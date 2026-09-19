# frozen_string_literal: true

# Switches and delivery for the automated emails (Task 12, Novu added in Task 16).
#
# Two delivery providers, chosen by `provider`:
#
#   :novu — each email is one Novu workflow trigger (NovuDeliveryJob →
#           NovuClient). Templates, the sender and the email provider (SES,
#           SendGrid, SMTP …) live in Novu.
#   :smtp — the original path: NotificationMailer#deliver_later over the SMTP
#           settings in config/environments/production.rb. Kept as fallback.
#
# Who gets an email (opt-outs, locked users, app members) is decided in Rails
# either way; Novu only delivers. The jobs call the `deliver_*` methods below
# and don't know which provider is active.
module EmailNotifications
  SILENCE_KEY = :zealot_email_notifications_silenced

  # Trigger identifiers of the three Novu workflows. Create workflows with
  # these identifiers in the Novu dashboard, or override them via ENV.
  DEFAULT_WORKFLOWS = {
    release_deployed: 'zealot-release-deployed',
    notice: 'zealot-notice',
    campaign: 'zealot-campaign'
  }.freeze

  module_function

  # ---- switches ----------------------------------------------------------

  # ZEALOT_EMAIL_PROVIDER=smtp|novu forces one (smtp is the rollback switch).
  # Unset: Novu when NOVU_API_KEY is present, otherwise SMTP.
  def provider
    case ENV['ZEALOT_EMAIL_PROVIDER'].to_s.strip.downcase
    when 'smtp' then :smtp
    when 'novu' then :novu
    else NovuClient.configured? ? :novu : :smtp
    end
  end

  def novu?
    provider == :novu
  end

  # Is the active provider set up well enough to deliver?
  def configured?
    return NovuClient.configured? if novu?
    return true unless Rails.env.production?

    smtp_configured?
  end

  # render.yaml declares the SMTP_* keys with `value: false`, which lands as the
  # literal string "false" on a service nobody has set SMTP up on.
  def smtp_configured?
    !ENV['SMTP_ADDRESS'].to_s.strip.downcase.in?(['', 'false'])
  end

  # Off when ZEALOT_EMAIL_NOTIFICATIONS_ENABLED is false, inside `silenced`, and
  # while the active provider isn't configured (so unconfigured deploys don't
  # fill the job queue with mails that cannot be delivered).
  def enabled?
    return false if Thread.current[SILENCE_KEY]
    return false unless ActiveModel::Type::Boolean.new.cast(ENV.fetch('ZEALOT_EMAIL_NOTIFICATIONS_ENABLED', 'true'))

    configured?
  end

  # Create records without emailing anyone (seed / sample data).
  def silenced
    previous = Thread.current[SILENCE_KEY]
    Thread.current[SILENCE_KEY] = true
    yield
  ensure
    Thread.current[SILENCE_KEY] = previous
  end

  def workflow_id(name)
    ENV["NOVU_WORKFLOW_#{name.to_s.upcase}"].to_s.strip.presence || DEFAULT_WORKFLOWS.fetch(name.to_sym)
  end

  # ---- delivery (called from the jobs) -----------------------------------

  def deliver_release_deployed(release, user)
    return NotificationMailer.release_deployed(release, user).deliver_later unless novu?

    enqueue_novu(:release_deployed, :deploys, user, "release-#{release.id}-user-#{user.id}",
                 release_deployed_payload(release, user))
  end

  # `broadcast_id` identifies one send-out (the fan-out job's id), so a re-run
  # of the same broadcast can't email anybody twice.
  def deliver_notice(user, subject:, body:, app: nil, broadcast_id: SecureRandom.uuid)
    return NotificationMailer.notice(user, subject: subject, body: body, app: app).deliver_later unless novu?

    enqueue_novu(:notice, :notices, user, "notice-#{broadcast_id}-user-#{user.id}",
                 broadcast_payload(user, :notices, subject, body, app: app))
  end

  def deliver_campaign(user, subject:, body:, broadcast_id: SecureRandom.uuid)
    return NotificationMailer.campaign(user, subject: subject, body: body).deliver_later unless novu?

    enqueue_novu(:campaign, :campaigns, user, "campaign-#{broadcast_id}-user-#{user.id}",
                 broadcast_payload(user, :campaigns, subject, body))
  end

  # Synchronous, raises on failure — for `rake zealot:email:test`.
  def deliver_test_via_novu!(user, subject:, body:)
    NovuClient.trigger(
      workflow_id: workflow_id(:notice),
      to: novu_subscriber(user),
      payload: broadcast_payload(user, :notices, subject, body),
      transaction_id: "test-#{SecureRandom.uuid}"
    )
  end

  # ---- Novu plumbing -----------------------------------------------------

  # Novu creates/updates the subscriber from this on every trigger, so there is
  # no separate "sync users to Novu" step. The id is prefixed so a shared Novu
  # environment can't collide with another app's numeric ids.
  def novu_subscriber(user)
    {
      subscriberId: "zealot-#{user.id}",
      email: user.email,
      firstName: user.username.presence,
      locale: user.locale.presence
    }.compact
  end

  def enqueue_novu(name, kind, user, transaction_id, payload)
    NovuDeliveryJob.perform_later(workflow_id(name), user.id, kind.to_s, payload, transaction_id)
  end

  # Copy is rendered here, in the recipient's locale (en / zh-CN), from the same
  # notification_mailer.* locale keys the SMTP templates use. Novu templates
  # only lay the fields out — see the payload contract in handover.md.
  def release_deployed_payload(release, user)
    with_user_locale(user) do
      version = release.release_version.to_s
      version += " (#{release.build_version})" if release.build_version.present?
      app_name = release.app_name

      common_payload(user, :deploys).merge(
        subject: I18n.t('notification_mailer.release_deployed.subject', app: app_name, version: version),
        heading: I18n.t('notification_mailer.release_deployed.heading', app: app_name),
        intro: I18n.t('notification_mailer.release_deployed.intro', version: version),
        changelogTitle: I18n.t('notification_mailer.release_deployed.changelog'),
        changelog: changelog_lines(release),
        openLabel: I18n.t('notification_mailer.release_deployed.open'),
        releaseUrl: release.release_url,
        appName: app_name,
        version: version
      )
    end
  end

  # Notice / campaign text is operator-typed plain text. `body` is the raw text;
  # `paragraphs` is the same text split on blank lines. Novu must render both
  # as text (escaped), never as HTML.
  def broadcast_payload(user, kind, subject, body, app: nil)
    with_user_locale(user) do
      payload = common_payload(user, kind).merge(
        subject: subject.to_s,
        body: body.to_s,
        paragraphs: body.to_s.split(/\r?\n\s*\r?\n/).map(&:strip).reject(&:blank?)
      )
      if app
        payload[:appName] = app.name
        payload[:appLine] = I18n.t('notification_mailer.notice.about_app', app: app.name)
      end
      payload
    end
  end

  def common_payload(user, kind)
    {
      siteTitle: Setting.site_title,
      siteUrl: Rails.application.routes.url_helpers.root_url,
      footer: I18n.t('notification_mailer.footer.why_kind',
                     kind: I18n.t("notification_mailer.footer.kinds.#{kind}")),
      manageLabel: I18n.t('notification_mailer.footer.manage'),
      preferencesUrl: Rails.application.routes.url_helpers.email_preferences_url(user.email_preferences_token)
    }
  end

  def with_user_locale(user, &block)
    I18n.with_locale(user.locale.presence || I18n.default_locale, &block)
  end

  # `changelog` is a jsonb array of { "message" => "..." } hashes (or blank).
  def changelog_lines(release)
    Array(release.changelog).filter_map do |entry|
      line = entry.is_a?(Hash) ? (entry['message'] || entry[:message]) : entry
      line.to_s.strip.presence
    end.first(20)
  end
end
