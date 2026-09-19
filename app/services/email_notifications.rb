# frozen_string_literal: true

# Switches for the automated emails (Task 12). Delivery itself is plain Rails:
# NotificationMailer#deliver_later on GoodJob, over the SMTP settings in
# config/environments/production.rb.
module EmailNotifications
  SILENCE_KEY = :zealot_email_notifications_silenced

  module_function

  # Off when ZEALOT_EMAIL_NOTIFICATIONS_ENABLED is false, inside `silenced`, and
  # in production until SMTP_ADDRESS is configured (so unconfigured deploys
  # don't fill the job queue with mails that cannot be delivered).
  def enabled?
    return false if Thread.current[SILENCE_KEY]
    return false unless ActiveModel::Type::Boolean.new.cast(ENV.fetch('ZEALOT_EMAIL_NOTIFICATIONS_ENABLED', 'true'))
    return true unless Rails.env.production?

    ENV['SMTP_ADDRESS'].present?
  end

  # Create records without emailing anyone (seed / sample data).
  def silenced
    previous = Thread.current[SILENCE_KEY]
    Thread.current[SILENCE_KEY] = true
    yield
  ensure
    Thread.current[SILENCE_KEY] = previous
  end
end
