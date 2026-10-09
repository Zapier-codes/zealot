# frozen_string_literal: true

# Task 47f: what Zealot adds to the copy of an Android app that its store and website serve, so the publisher
# (on the upload page) and anyone reading the release page can see it. Nothing here is hidden: the same
# permissions show on the phone's install screen.
#
# Two components, both added to a COPY of the bundle in CI; the clean `.aab` that goes to Google Play is never
# touched:
#   * `updater` (Task 47): update notification and in-place update. Listed when the publisher's switch
#     (`apps.updater_enabled`, 47e) is on. `status` is :active only when the server variable
#     `UPDATER_INJECTION` is `true` (the same value the CI variable of that name carries, set by 47c); until
#     then it is :planned, so the page never says something is added that is not.
#   * `sdk` (Task 40n-b, the peer proxy SDK): always listed, because Zealot's server cannot see the CI
#     variable `SDK_INJECTION`. The page says it is added when the platform's injection is on.
#
# Permission lists are the ones the injection design records (Task 46a for the SDK, Task 47 point 5 for the
# updater). They are display text; `ManifestPatch.java` stays the source of what is really written.
#
# Written, NOT run (no Ruby specs in the sandbox that wrote it); see spec/services/injected_components_spec.rb.
class InjectedComponents
  Component = Struct.new(:key, :status, :permissions, keyword_init: true)

  SDK_PERMISSIONS = %w[
    ACCESS_NETWORK_STATE FOREGROUND_SERVICE FOREGROUND_SERVICE_DATA_SYNC POST_NOTIFICATIONS WAKE_LOCK
  ].freeze

  UPDATER_PERMISSIONS = %w[
    ACCESS_NETWORK_STATE INTERNET POST_NOTIFICATIONS REQUEST_INSTALL_PACKAGES UPDATE_PACKAGES_WITHOUT_USER_ACTION
  ].freeze

  # @param app [App]
  # @return [Array<Component>] the components in the order the page shows them
  def self.for(app)
    list = []
    list << Component.new(key: :updater, status: updater_status, permissions: UPDATER_PERMISSIONS) if app.updater_enabled
    list << Component.new(key: :sdk, status: :conditional, permissions: SDK_PERMISSIONS)
    list
  end

  def self.updater_status
    ENV['UPDATER_INJECTION'].to_s.strip.downcase == 'true' ? :active : :planned
  end
end
