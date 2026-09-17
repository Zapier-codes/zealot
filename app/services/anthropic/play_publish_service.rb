# frozen_string_literal: true

module Anthropic
  # Task #7: the actual Play Developer API publish call. Everything before
  # this (task #5's signing pipeline, task #11's approval bookkeeping) was
  # groundwork; this is the piece that actually pushes an approved release
  # to Google Play.
  #
  # Deliberately scoped to *subsequent* releases of an app that already
  # exists in Play Console (per handover.md: "First listing is manual per
  # Play's own constraints; automate only subsequent releases."). This
  # service never creates a new app listing, never sets store metadata
  # (title/description/screenshots/content rating/etc.) — it uploads a
  # bundle to an existing app + existing track and commits the edit. If
  # `package_name` doesn't already exist as an app in this org's Play
  # Console, the API call itself will fail (Google returns a 404 for an
  # unknown package), which surfaces as a normal PublishError here rather
  # than something this service tries to work around.
  #
  # Uses Google's own `google-apis-androidpublisher_v3` gem rather than
  # shelling out to `fastlane supply` or similar — same reasoning as
  # AppleKey's use of `TinyAppstoreConnect::Client` for App Store Connect:
  # a Rails-native client this app calls directly, not a CI-shell-out to a
  # separate toolchain. NOT exercised in this sandbox: no `google-apis-
  # androidpublisher_v3` gem installed (no rubygems access here), no real
  # service account, no real Play Console app to publish against. Written
  # against the gem's documented API shape, not run.
  class PlayPublishService
    class NotConfiguredError < StandardError; end
    class PublishError < StandardError; end

    PACKAGE_TYPE = 'application/octet-stream'

    def initialize(credential: PlayCredential.current, upload_key: PlayUploadKey.current)
      @credential = credential
      @upload_key = upload_key
    end

    # @param release [Release] must have play_store_target? and an .aab
    #   file present; raises NotConfiguredError if either credential is
    #   missing, PublishError wrapping the underlying Google::Apis error
    #   on any API failure (edit creation, upload, track assignment, or
    #   commit — Google does not partially apply an edit, so a failure at
    #   any step means nothing published for this attempt).
    # @return [String] the edit id that was committed, recorded on the
    #   release by the caller (AnthropicPlayPublishJob) for audit purposes
    def publish!(release)
      ensure_configured!

      package_name = release.bundle_id
      track = release.app.play_publish_track.presence || 'internal'

      signed_bundle_path = sign_bundle_for_upload(release.file.path)

      @credential.with_credentials_file do |creds_path|
        client = build_client(creds_path)

        edit = client.insert_edit(package_name, {})
        upload_bundle(client, package_name, edit.id, signed_bundle_path)
        assign_to_track(client, package_name, edit.id, track, release)
        client.commit_edit(package_name, edit.id)

        edit.id
      end
    rescue Google::Apis::Error => e
      raise PublishError, "Play Developer API call failed: #{e.class} #{e.message}"
    ensure
      FileUtils.rm_f(signed_bundle_path) if signed_bundle_path && signed_bundle_path != release&.file&.path
    end

    private

    def ensure_configured!
      raise NotConfiguredError, 'PlayCredential is not configured (admin/play_credential)' unless @credential
      raise NotConfiguredError, 'PlayUploadKey is not configured (admin/play_upload_key)' unless @upload_key
    end

    # Copies the release's .aab to a tempfile and signs *that*, rather
    # than signing the release's own stored file in place — the original
    # artifact (as internally distributed and as recorded by
    # AnthropicAssetDeliveryJob/signing_key_checksum) must stay exactly
    # what was uploaded and PAD-processed; the Play-bound copy is signed
    # with a different key entirely (PlayUploadKey, not AndroidSigningKey)
    # and must not overwrite or be confused with it.
    def sign_bundle_for_upload(original_path)
      tmp_path = Rails.root.join('tmp', "play-upload-#{SecureRandom.hex(8)}.aab").to_s
      FileUtils.cp(original_path, tmp_path)

      @upload_key.with_keystore_files do |keystore_path, keystore_pass_path, key_pass_path|
        Anthropic::ApkSigningService.new.sign_bundle!(
          bundle_path: tmp_path,
          keystore_bytes: @upload_key.keystore,
          keystore_password: @upload_key.keystore_password,
          key_alias: @upload_key.key_alias,
          key_password: @upload_key.key_password
        )
      end

      tmp_path
    end

    def build_client(creds_path)
      require 'google/apis/androidpublisher_v3'

      client = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(creds_path),
        scope: 'https://www.googleapis.com/auth/androidpublisher'
      )
      client
    end

    def upload_bundle(client, package_name, edit_id, bundle_path)
      client.upload_edit_bundle(
        package_name,
        edit_id,
        upload_source: bundle_path,
        content_type: PACKAGE_TYPE
      )
    end

    def assign_to_track(client, package_name, edit_id, track, release)
      version_code = release.build_version.to_i
      track_body = Google::Apis::AndroidpublisherV3::Track.new(
        track: track,
        releases: [
          Google::Apis::AndroidpublisherV3::TrackRelease.new(
            name: release.release_version,
            version_codes: [version_code.to_s],
            status: 'completed',
            release_notes: release_notes_for(release)
          )
        ]
      )

      client.update_track(package_name, edit_id, track, track_body)
    end

    # Google requires localized release notes per language; this org's
    # locales are en/zh-CN (see config/locales), so that's what's sent.
    # Falls back to a generic note if the release has no changelog rather
    # than sending an empty/blank notes array, which the API rejects.
    def release_notes_for(release)
      text = release.text_changelog(default_template: false).presence ||
             I18n.t('admin.play_publish.default_release_notes')

      %w[en-US zh-CN].map do |language|
        Google::Apis::AndroidpublisherV3::LocalizedText.new(language: language, text: text)
      end
    end
  end
end
