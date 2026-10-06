# frozen_string_literal: true

# Task 41a: the base name every stored file of a release is called, built from the app's own data instead of
# from whatever the uploader's tool produced (Gradle's `app-default-release.aab`) or a name typed into a
# workflow (`universal.apk`). `Storeapp` 1.1.4, build 218 gives `Storeapp-1.1.4-218`, and the stored files are
# `Storeapp-1.1.4-218.aab`, `Storeapp-1.1.4-218.apk`, `Storeapp-1.1.4-218.apks.br` and an icon of that name.
#
# Zealot computes it once and hands it to CI (the stage-1 answer's `artifact_base`); CI only uses it. The apps
# table has no slug, so the display name is used, cleaned to the characters the workflows and the storage
# adapter accept (`[A-Za-z0-9._-]`): accents are transliterated, every other run of characters becomes one
# hyphen, and hyphens and dots are trimmed from both ends of each part. Each part is bounded, so the whole
# name stays well under the limits of a file name and of a GitHub asset name, and it is never empty.
#
# Pure: reads the release and its app, touches no storage and no network.
class ReleaseArtifactName
  FALLBACK_APP = 'app'
  MAX_APP = 60
  MAX_VERSION = 24
  MAX_BUILD = 16
  UNSAFE = /[^A-Za-z0-9._-]+/
  VALID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  # @param release [Release]
  # @return [String] e.g. `Storeapp-1.1.4-218`; always matches VALID
  def self.for(release)
    app_part = clean(release.app&.name, MAX_APP).presence || FALLBACK_APP
    parts = [app_part, clean(release.release_version, MAX_VERSION), clean(release.build_version, MAX_BUILD)]
    parts.reject(&:blank?).join('-')
  end

  # @param text [#to_s, nil]
  # @param max [Integer]
  # @return [String] possibly empty
  def self.clean(text, max)
    cleaned = I18n.transliterate(text.to_s, replacement: '-').gsub(UNSAFE, '-').squeeze('-').squeeze('.')
    cleaned = cleaned.gsub(/\A[-.]+|[-.]+\z/, '')
    cleaned[0, max].to_s.gsub(/[-.]+\z/, '')
  end
  private_class_method :clean
end
