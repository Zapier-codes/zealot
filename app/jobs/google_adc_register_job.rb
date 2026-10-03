# frozen_string_literal: true

# Task 36b-6: after Zealot signs a release with the organisation's key, register that release's
# package name with Google (see GoogleAdc::Registrar and handover.md, "Task 36b").
#
# Enqueued by AnthropicAssetDeliveryJob, and only when ADC_AUTO_REGISTER=true (decision 36-3). It is
# best effort in the same way that job is: a failure is logged and recorded on the registration row,
# and never reaches the upload that caused it.
#
# It reads the app UNSCOPED (decision 36-7). Tenant scopes decide what a person may see; this job
# acts for the organisation on every tenant's apps, so a tenant-scoped read would silently skip them.
#
# Only a release that Zealot itself signed with the CURRENT organisation key is registered
# (decision 36-4): an .apk upload keeps its uploader's signature, and claiming our key for it would
# be wrong.
class GoogleAdcRegisterJob < ApplicationJob
  queue_as :default

  # Network trouble, 429 and 5xx from Google. Everything else is recorded, not retried.
  retry_on GoogleAdc::TemporaryError, wait: :polynomially_longer, attempts: 5

  def perform(release_id)
    return unless GoogleAdc.auto_register?
    return unless GoogleAdc::Client.configured?

    release = Release.find_by(id: release_id)
    return unless release

    key = AndroidSigningKey.current
    return unless key && release.signed? && release.signing_key_checksum == key.checksum

    app = release.app
    package_name = package_name_for(app, release)
    return if package_name.blank?

    result = GoogleAdc::Registrar.call(package_name: package_name, app: app)
    logger.info("[GoogleAdcRegisterJob] #{package_name}: #{result.outcome}")
  rescue GoogleAdc::TemporaryError
    raise
  rescue StandardError => e
    logger.error("[GoogleAdcRegisterJob] failed for release #{release_id}: #{e.class}: #{e.message}")
  end

  private

  # Decision 36-5. A channel's `bundle_id` defaults to '*' (a wildcard, not a name), and a release's
  # own `bundle_id` may be nil; the format check in the Registrar rejects anything that is not a
  # real Android application id.
  def package_name_for(app, release)
    app&.play_package_name.presence || release.bundle_id.presence
  end
end
