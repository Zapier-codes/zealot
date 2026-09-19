# frozen_string_literal: true

module Anthropic
  # Task 18: the automated version of the manual "play-check" — asks Google
  # whether it can open (and immediately discard) an edit for a package
  # name. A returned edit id means the Google-side setup is finished: the
  # app exists in Play Console, its first bundle has been uploaded, and the
  # service account can edit it.
  #
  # Why this exists: Play Console's "Create app" form has no package name.
  # The applicationId is fixed by the first bundle uploaded, so until then
  # the API answers `404 Package not found`. That first upload can't be
  # done through the API, so it is the one manual step in the flow (this
  # instance's single service account already covers every app, so nothing
  # needs inviting). This service tells us — cheaply, and
  # without signing/uploading anything — which of the possible causes
  # applies, so the developer gets an actionable message and Zealot can
  # resume the publish by itself once it is fixed.
  #
  # Written against the documented google-apis-androidpublisher_v3 shape;
  # NOT exercised in the sandbox this was written in (no gem access, no
  # real service account, no real Play Console app).
  class PlayPreflightService
    # code: :ready, :no_package_name, :package_not_found, :access_denied,
    #       :not_configured, :auth_failed or :error
    APP_STATUS = {
      ready: :ready,
      no_package_name: :unchecked,
      package_not_found: :needs_first_upload,
      access_denied: :needs_access,
      not_configured: :needs_credentials,
      auth_failed: :needs_credentials,
      error: :check_failed
    }.freeze

    Result = Struct.new(:code, :package_name, :message, :edit_id, keyword_init: true) do
      def ready?
        code == :ready
      end

      # The one Play Console step a human has to do by hand (the first
      # bundle upload of a new app), after which Zealot can carry on by
      # itself. Everything else — credential problems, a service account
      # that lost access, unexpected errors — stays a plain failure: this
      # instance uses a single service account that already covers every
      # app, so there is nothing to invite or wait for.
      def waiting_for_setup?
        code == :package_not_found
      end

      # The matching App#play_setup_status value.
      def app_status
        APP_STATUS.fetch(code)
      end
    end

    SCOPE = 'https://www.googleapis.com/auth/androidpublisher'

    def initialize(credential: PlayCredential.current)
      @credential = credential
    end

    # @param package_name [String, nil] the applicationId to probe
    # @return [Result] never raises for API/credential problems — they are
    #   the point of the check and are reported as a Result code
    def check(package_name)
      package_name = package_name.to_s.strip
      return build(:no_package_name) if package_name.blank?
      return build(:not_configured, package_name: package_name) unless @credential

      require 'google/apis/androidpublisher_v3'
      probe(package_name)
    end

    private

    def probe(package_name)
      @credential.with_credentials_file do |creds_path|
        client = build_client(creds_path)
        edit = client.insert_edit(package_name, {})
        discard_edit(client, package_name, edit.id)

        build(:ready, package_name: package_name, edit_id: edit.id)
      end
    rescue Google::Apis::AuthorizationError => e
      build(:auth_failed, package_name: package_name, detail: e.message)
    rescue Google::Apis::ClientError => e
      case e.status_code
      when 404 then build(:package_not_found, package_name: package_name)
      when 403 then build(:access_denied, package_name: package_name)
      else build(:error, package_name: package_name, detail: "#{e.class} #{e.message}")
      end
    rescue StandardError => e
      # Bad service-account keys surface as Signet::AuthorizationError,
      # which isn't guaranteed to be loaded (so it is matched by name).
      code = e.class.name.to_s.start_with?('Signet::') ? :auth_failed : :error
      build(code, package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    # Same client setup as PlayPublishService#build_client (kept separate
    # on purpose so the working publish path isn't touched by this task).
    def build_client(creds_path)
      client = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(creds_path),
        scope: SCOPE
      )
      client
    end

    # Best effort: an unused edit expires on Google's side anyway.
    def discard_edit(client, package_name, edit_id)
      client.delete_edit(package_name, edit_id)
    rescue StandardError
      nil
    end

    def build(code, package_name: nil, detail: nil, edit_id: nil)
      Result.new(
        code: code,
        package_name: package_name,
        edit_id: edit_id,
        message: message_for(code, package_name: package_name, detail: detail)
      )
    end

    # Stored on the App/Release, so written in the site locale (same as the
    # Play-publish-failed notice in Release).
    def message_for(code, package_name:, detail:)
      I18n.with_locale(Setting.site_locale) do
        I18n.t("admin.play_preflight.messages.#{code}",
               package: package_name,
               email: @credential&.service_account_email,
               detail: detail)
      end
    end
  end
end
