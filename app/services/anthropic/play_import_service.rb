# frozen_string_literal: true

module Anthropic
  # Z-P25 §2: the *read* side of the Play Developer API. PlayPublishService and
  # PlayPreflightService only ever write (probe an edit, upload a bundle, commit a
  # track); nothing brought an existing Play listing *back* into Zealot. This does:
  # it opens a Play edit, reads the app's store listings (per language) and its
  # tracks, then discards the edit without committing anything.
  #
  # It is the counterpart to PlayPublishService and deliberately shares its shape:
  # the same PlayCredential (org-wide service account), the same client-building
  # code, and the same never-raises contract as PlayPreflightService — an API or
  # credential problem is a Result code, not an exception, because the whole point
  # of the page is to tell the developer what Play answered.
  #
  # Uses Google's own `google-apis-androidpublisher_v3` gem (see the Gemfile), not
  # a reverse-engineered client: this is the official Play Developer API, so a
  # publisher only needs to grant the service account access, exactly as the
  # publish path already requires.
  #
  # Scoped for now to listing text and tracks. Reviews and vitals are a deliberate
  # follow-on (different endpoints, different models) and are not read here.
  #
  # Written against the documented google-apis-androidpublisher_v3 shape; NOT
  # exercised end-to-end in the sandbox this was written in (no gem install, no
  # real service account, no Play Console app). The pure mapping is covered by a
  # stubbed harness.
  class PlayImportService
    # code: :ok, :no_package_name, :not_configured, :package_not_found,
    #       :access_denied, :auth_failed or :error
    #
    # One store listing as Play holds it, for one language. Field names match
    # Play's own (`title`/`short_description`/`full_description`), not Zealot's
    # App columns -- the controller maps them, so this stays a faithful read.
    Listing = Struct.new(:language, :title, :short_description, :full_description, keyword_init: true) do
      def blank?
        [title, short_description, full_description].all? { |v| v.to_s.strip.empty? }
      end
    end

    # One track as Play holds it, with the status and version codes of its
    # releases. Read-only: nothing here is staged or published.
    TrackInfo = Struct.new(:track, :status, :version_codes, keyword_init: true) do
      def self.from_play(track)
        releases = Array(track.releases)
        TrackInfo.new(
          track: track.track,
          status: releases.map(&:status).compact.uniq.first,
          version_codes: releases.flat_map { |r| Array(r.version_codes) }.map(&:to_s)
        )
      end
    end

    Result = Struct.new(:code, :package_name, :listings, :tracks, :message, keyword_init: true) do
      def ok?
        code == :ok
      end

      # The listing a person most likely wants pre-filled: en-US, else any
      # English, else the first one Play returned. nil when there is none.
      def preferred_listing
        return nil if listings.blank?

        listings.find { |l| l.language == 'en-US' } ||
          listings.find { |l| l.language.to_s.start_with?('en') } ||
          listings.first
      end
    end

    SCOPE = 'https://www.googleapis.com/auth/androidpublisher'

    def initialize(credential: PlayCredential.current)
      @credential = credential
    end

    # @param package_name [String, nil] the applicationId to read
    # @return [Result] never raises for API/credential problems -- they are
    #   reported as a Result code
    def fetch(package_name)
      package_name = package_name.to_s.strip
      return build(:no_package_name) if package_name.blank?
      return build(:not_configured, package_name: package_name) unless @credential

      require 'google/apis/androidpublisher_v3'
      read(package_name)
    rescue LoadError => e
      # LoadError is a ScriptError, not a StandardError, so it is caught here
      # rather than in `read`'s rescue chain: the gem missing is a deployment
      # problem to report, never a crash on the operator's page.
      build(:error, package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    private

    def read(package_name)
      @credential.with_credentials_file do |creds_path|
        client = build_client(creds_path)

        # An edit is how the API exposes an app's current state; it is opened
        # only to read and thrown away, so nothing is ever changed.
        edit = client.insert_edit(package_name, {})
        begin
          listings = map_listings(client.list_edit_listings(package_name, edit.id))
          tracks = map_tracks(client.list_edit_tracks(package_name, edit.id))
        ensure
          discard_edit(client, package_name, edit.id)
        end

        build(:ok, package_name: package_name, listings: listings, tracks: tracks)
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
      # A bad service-account key surfaces as Signet::AuthorizationError, which
      # is not guaranteed to be loaded, so it is matched by name (as preflight does).
      code = e.class.name.to_s.start_with?('Signet::') ? :auth_failed : :error
      build(code, package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    def map_listings(response)
      Array(response&.listings).map do |listing|
        Listing.new(
          language: listing.language,
          title: listing.title,
          short_description: listing.short_description,
          full_description: listing.full_description
        )
      end
    end

    def map_tracks(response)
      Array(response&.tracks).map { |track| TrackInfo.from_play(track) }
    end

    # Same client setup as PlayPublishService/PlayPreflightService#build_client
    # (kept separate on purpose so the working publish path isn't touched).
    def build_client(creds_path)
      client = Google::Apis::AndroidpublisherV3::AndroidPublisherService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(creds_path),
        scope: SCOPE
      )
      client
    end

    # Best effort: the edit was opened to read, and an unused edit expires on
    # Google's side anyway -- a failure to discard must not fail the read.
    def discard_edit(client, package_name, edit_id)
      client.delete_edit(package_name, edit_id)
    rescue StandardError
      nil
    end

    def build(code, package_name: nil, listings: nil, tracks: nil, detail: nil)
      Result.new(
        code: code,
        package_name: package_name,
        listings: listings,
        tracks: tracks,
        message: message_for(code, package_name: package_name, detail: detail)
      )
    end

    # Stored/shown in the site locale, the same way PlayPreflightService writes
    # its messages.
    def message_for(code, package_name:, detail:)
      I18n.with_locale(Setting.site_locale) do
        I18n.t("admin.play_import.messages.#{code}",
               package: package_name,
               email: @credential&.service_account_email,
               detail: detail)
      end
    end
  end
end
