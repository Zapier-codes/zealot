# frozen_string_literal: true

# The base name every stored file of a release is called, built from the app's own data instead of from whatever
# the uploader's tool produced (Gradle's `app-default-release.aab`) or a name typed into a workflow
# (`universal.apk`).
#
# Task 44b (operator, 2026-10-07): the base is the app's name and the version, nothing else, never the build
# number and never a timestamp. `Appstore` 1.1.4 gives `appstore-1.1.4`, and the stored files are
# `appstore-1.1.4.aab`, `appstore-1.1.4.apk`, `appstore-1.1.4.apks.br` and an icon of that name. The name part is
# `NameSlug.base(app.name)` (lowercase, `[a-z0-9-]`), the version keeps its own case. Two builds of one version
# can not collide: every release has its own storage release (`a<app>-r<release>`).
#
# Task 41a (superseded in part): the base used to be `<Name>-<version>-<build>` (`Storeapp-1.1.4-218`), with the
# name's own case. That form is kept as `.previous_for` only so stage 3 still accepts an upload whose stage 1
# ran before Task 44 was deployed; nothing new is named with it.
#
# Zealot computes the base once and hands it to CI (the stage-1 answer's `artifact_base`, the compile dispatch's
# input); CI only validates its shape and uses it. Releases already stored keep the keys recorded on them.
#
# Pure: reads the release and its app, touches no storage and no network. Characters are restricted to
# `[A-Za-z0-9._-]` (what the workflows and the storage adapter accept), the parts are bounded, and the result is
# never empty.
class ReleaseArtifactName
  FALLBACK_APP = 'app'
  MAX_APP = 60
  MAX_VERSION = 24
  MAX_BUILD = 16
  UNSAFE = /[^A-Za-z0-9._-]+/
  VALID = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  # @param release [Release]
  # @return [String] e.g. `appstore-1.1.4`; always matches VALID
  def self.for(release)
    app_part = NameSlug.base(release.app&.name).presence || FALLBACK_APP
    [app_part, clean(release.release_version, MAX_VERSION)].reject(&:blank?).join('-')
  end

  # The name before Task 44 (Task 41a): the app's name with its own case, the version and the build.
  #
  # @param release [Release]
  # @return [String] e.g. `Storeapp-1.1.4-218`; always matches VALID
  def self.previous_for(release)
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
