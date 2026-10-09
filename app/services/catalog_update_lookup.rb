# frozen_string_literal: true

# Task 47d: what `GET /catalog/updates/:package_name` answers. One package name in, the newest version of that
# app a device can install in place, or nil.
#
# The caller is the `ZealotUpdater` library injected into a published app (Task 47a), so every rule here is
# "never offer a file that cannot be installed":
#
#   * the app is live in the default tenant's catalog (`App.listing_live`, the same set as /catalog/index.json),
#     is not archived, and has this `play_package_name`;
#   * the release is one the public index lists (`App#catalog_releases`: production channels, never held),
#     is `available` (a halted or pulled release is not offered), and has a recorded compiled universal APK
#     (`Release#serves_universal_apk?`), because that signed file is the one an in-place update installs and
#     the one whose size and SHA-256 the library verifies;
#   * "newest" is the highest `build_version` compared as a version (`VersionCompare`, so "100" beats "99"),
#     not the newest upload; a code that does not parse never beats one that does; between equal codes the
#     newest upload wins.
#
# The answer is the same for every caller: the request carries the package name and nothing else. The library
# compares `version_code` with its own installed one. No device id, no account, nothing logged per device.
#
# Fields not stored anywhere are left out, never invented: `min_supported_version_code` has no column yet (47e
# or later), so it is absent from the answer.
#
# Written, NOT run (no Ruby in the sandbox that wrote it); see spec/services/catalog_update_lookup_spec.rb.
class CatalogUpdateLookup
  def self.call(package_name)
    new(package_name).call
  end

  def initialize(package_name)
    @package_name = package_name.to_s
  end

  # @return [Hash, nil] the answer, or nil when the package is unknown, not live, or has nothing installable
  def call
    return nil unless package_name.match?(App::PLAY_PACKAGE_NAME_FORMAT)

    app = App.listing_live.for_tenant(nil).where(archived: false).find_by(play_package_name: package_name)
    return nil unless app

    release = newest_installable(app)
    release && answer_for(release)
  end

  private

  attr_reader :package_name

  def newest_installable(app)
    candidates = app.catalog_releases.to_a.select do |release|
      release.status == 'available' && release.serves_universal_apk?
    end
    # `catalog_releases` is newest first, so the first of equal codes stays.
    candidates.reduce do |kept, candidate|
      (compare(candidate.build_version, kept.build_version) == 1) ? candidate : kept
    end
  end

  # 1 when `a` is a higher version than `b`. A code that is blank or not a version loses to one that is.
  def compare(a, b)
    key_a = version_key(a)
    key_b = version_key(b)
    return 0 if key_a.nil? && key_b.nil?
    return -1 if key_a.nil?
    return 1 if key_b.nil?

    key_a <=> key_b
  end

  def version_key(code)
    return nil if code.blank?

    @version_compare ||= Object.new.extend(VersionCompare)
    Gem::Version.new(@version_compare.semver(code))
  rescue ArgumentError
    nil
  end

  def answer_for(release)
    {
      package_name: package_name,
      release_id: release.id,
      version_code: release.build_version,
      version_name: release.release_version,
      download_url: release.download_url,
      sha256: release.universal_apk_sha256,
      size_bytes: release.universal_apk_size,
      signing_fingerprint: release.signing_key_checksum,
      min_sdk: release.min_sdk_version,
      changelog: release.text_changelog(default_template: false).presence,
      released_at: release.created_at&.utc&.iso8601,
    }
  end
end
