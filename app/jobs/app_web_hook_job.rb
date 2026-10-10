# frozen_string_literal: true

class AppWebHookJob < ApplicationJob
  include Rails.application.routes.url_helpers
  include ActionView::Helpers::DateHelper
  include ActionView::Helpers::TranslationHelper
  include ActiveSupport::NumberHelper

  queue_as :webhook

  # Automatically retry on network errors with exponential backoff
  retry_on Faraday::Error, wait: :exponentially_longer, attempts: 3 do |job, error|
    job.send(:handle_webhook_failure, error)
  end

  def perform(event, web_hook, channel, user_id)
    @event = event
    @web_hook = web_hook
    @channel = channel
    @release = @channel.releases.last
    @user = User.find(user_id)

    if @release.blank?
      logger.error(log_message(t('active_job.webhook.failures.empty_release')))
      return notificate_failure(
        user_id: @user.id,
        type: 'webhook',
        message: t('active_job.webhook.failures.empty_release')
      )
    end

    if @web_hook.url.blank?
      logger.error(log_message(t('active_job.webhook.failures.empty_url')))
      return notificate_failure(
        user_id: @user.id,
        type: 'webhook',
        message: t('active_job.webhook.failures.empty_url')
      )
    end

    logger.info(log_message("trigger event: #{@event}"))
    logger.info(log_message("trigger url: #{@web_hook.url}"))
    logger.info(log_message("trigger json body: #{message_body}"))

    send_request
  end

  private

  def send_request
    headers = { 'Content-Type' => 'application/json' }.merge(signature_headers(message_body))
    response = Faraday.post(@web_hook.url, message_body, headers)
    logger.debug(log_message("trigger response body: #{response.body}"))
    if response.success?
      logger.info(log_message('trigger successfully'))
    else
      logger.error(log_message("trigger failed with status: #{response.status}"))
      raise Faraday::Error, "response status: #{response.status}"
    end
  end

  # Z-P19: when the hook has a signing secret, every delivery carries Standard Webhooks signature headers so
  # the receiver can prove the body came from Zealot and was not altered. A hook with no secret gets none,
  # exactly as before. The id and timestamp are also exposed as headers per the Standard Webhooks spec.
  def signature_headers(body)
    return {} unless @web_hook.signed?

    webhook_id = SecureRandom.uuid
    timestamp = Time.current.to_i
    signature = Webhooks::StandardSignature.header(
      secret: @web_hook.signing_secret, webhook_id: webhook_id, timestamp: timestamp, body: body
    )
    {
      'webhook-id' => webhook_id,
      'webhook-timestamp' => timestamp.to_s,
      'webhook-signature' => signature
    }
  end

  def message_body
    build(@web_hook.body.presence || default_body)
  end

  def build(body)
    ApplicationController.render inline: body,
                                 type: :jb,
                                 assigns: {
                                   event: @event,
                                   username: @user.username,
                                   email: @user.email,
                                   title: title,
                                   name: @release.name,
                                   app_name: @release.app_name,
                                   device_type: @channel.device_type,
                                   release_version: @release.release_version,
                                   build_version: @release.build_version,
                                   bundle_id: @release.bundle_id,
                                   changelog: @release.text_changelog,
                                   file_size: @release.file_size,
                                   release_url: @release.release_url,
                                   install_url: @release.install_url,
                                   icon_url: @release.icon_url,
                                   qrcode_url: @release.qrcode_url,
                                   uploaded_at: @release.created_at,
                                   ci_url: @release.ci_url,
                                   branch: @release.branch,
                                   source: @release.source,
                                   release_type: @release.release_type
                                 }
  end

  def default_body
    '{
      event: @event,
      username: @username,
      email: @email,
      title: @title,
      name: @app_name,
      app_name: @app_name,
      device_type: @device_type,
      release_version: @release_version,
      build_version: @build_version,
      size: @file_size,
      changelog: @changelog,
      release_url: @release_url,
      install_url: @install_url,
      icon_url: @icon_url,
      qrcode_url: @qrcode_url,
      uploaded_at: @uploaded_at,
      ci_url: @release.ci_url,
      branch: @release.branch,
      source: @release.source,
      release_type: @release.release_type
    }'
  end

  def title
    case @event
    when 'upload_events'
      t('teardowns.messages.upload_events', name: @release.app_name, version: @release.release_version)
    when 'download_events'
      t('teardowns.messages.download_events', name: @release.app_name, version: @release.release_version)
    when 'changelog_events'
      t('teardowns.messages.changelog_events', name: @release.app_name, version: @release.release_version)
    else
      t('teardowns.messages.unknown_events', name: @release.app_name, event: @event)
    end
  end

  def log_message(message)
    "[Channel] #{@channel.id} #{message}"
  end

  def handle_webhook_failure(error)
    _event, web_hook, _channel, user_id = arguments
    return if user_id.blank?

    notificate_failure(
      user_id: user_id,
      type: 'webhook',
      message: t('active_job.webhook.failures.send_failed', url: web_hook&.url, error: error.message)
    )
  end

  def build_example_release
    @channel.releases.build(
      name: 'Example App',
      bundle_id: 'im.ews.zealot.example.app',
      release_version: '1.0.0',
      build_version: '5',
      git_commit: '31dbb8497b81e103ecadcab0ca724c3fd87b3ab9'
    )
  end
end
