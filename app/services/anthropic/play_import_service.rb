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
  # Three reads, each independently failing so one API being disabled does not
  # blank the others (the page shows whichever answered):
  #
  #   * `fetch`          -- store listings (per language) and release tracks, via
  #                        an opened-then-discarded edit. Nothing is committed.
  #   * `fetch_reviews`  -- the app's Play reviews, newest first, with the
  #                        developer reply Play already holds. A plain app-level
  #                        read; no edit needed.
  #   * `fetch_vitals`   -- crash and ANR rate from Google's *other* API (the Play
  #                        Developer Reporting API, a separate gem and scope) over
  #                        a trailing window. Read-only.
  #
  # All three share the same never-raises contract: an API/credential problem is
  # a Result code, not an exception. Reviews and vitals are read for display here;
  # copying Play reviews into Zealot's own inbox (with replies synced back) is a
  # deliberate follow-on, so nothing is written and nothing is sent to Play.
  #
  # Written against the documented google-apis-androidpublisher_v3 and
  # google-apis-playdeveloperreporting_v1beta1 shapes; NOT exercised end-to-end in
  # the sandbox this was written in (no real service account, no Play Console app).
  # The pure mapping is covered by stub-driven harnesses and specs.
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

    # One review as Play holds it, flattened from Review -> Comment -> UserComment.
    # Text is whatever Play returned (translated when a translation language was
    # asked for); the reply is Play's own developer comment, read-only here.
    ReviewInfo = Struct.new(
      :review_id, :author_name, :rating, :text, :language,
      :device, :app_version_name, :last_modified, :developer_reply,
      :thumbs_up, :thumbs_down, :replied_at, keyword_init: true
    )

    ReviewsResult = Struct.new(:code, :package_name, :reviews, :message, keyword_init: true) do
      def ok?
        code == :ok
      end
    end

    # One vitals row: a crash/ANR rate and the distinct-user count it is normalised
    # by, for one interval. `value` stays nil when Play answered no datapoint for
    # the interval -- it is never turned into a 0, which would read as "no crashes".
    VitalInfo = Struct.new(:kind, :start_time, :aggregation_period, :value, :user_count, keyword_init: true)

    VitalsResult = Struct.new(:code, :package_name, :vitals, :window, :message, keyword_init: true) do
      def ok?
        code == :ok
      end

      def crash
        latest(VITALS_FEATURES.first)
      end

      def anr
        latest(VITALS_FEATURES.last)
      end

      # The most recent interval for the kind -- rows may arrive in any order, so
      # this sorts by the ISO start_time rather than trusting position.
      def latest(kind)
        Array(vitals).select { |v| v.kind == kind }.max_by { |v| v.start_time.to_s }
      end
    end

    SCOPE = 'https://www.googleapis.com/auth/androidpublisher'
    # The Play Developer Reporting API is a separate service with its own scope.
    REPORTING_SCOPE = 'https://www.googleapis.com/auth/playdeveloperreporting'
    # Trailing window the vitals read asks for, and the cap on rows kept per metric.
    VITALS_WINDOW_DAYS = 30
    VITALS_MAX_ROWS = 60
    # One page of reviews is enough to show the inbox; Play pages beyond this.
    REVIEWS_PAGE_SIZE = 100
    # Google's metric name for the normalising user count, asked for beside each
    # rate so a rate can be read as "0.41% of 1,203 users" rather than a bare number.
    DISTINCT_USERS = 'distinctUsers'
    QUERY_METHODS = { 'crashRate' => :query_vital_crashrate, 'anrRate' => :query_vital_anrrate }.freeze
    # The two rate metric sets read, in display order.
    VITALS_FEATURES = QUERY_METHODS.keys.freeze

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

    # Reads the app's Play reviews (newest first, as Play returns them), including
    # the developer reply Play already holds. A plain app-level read -- no edit.
    #
    # @param package_name [String, nil]
    # @param translation_language [String, nil] asks Play to translate review text
    # @return [ReviewsResult] never raises for API/credential problems
    def fetch_reviews(package_name, translation_language: nil)
      package_name = package_name.to_s.strip
      return build_reviews(:no_package_name) if package_name.blank?
      return build_reviews(:not_configured, package_name: package_name) unless @credential

      require 'google/apis/androidpublisher_v3'
      read_reviews(package_name, translation_language)
    rescue LoadError => e
      build_reviews(:error, package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    # Reads crash and ANR rate from the Play Developer Reporting API over the
    # trailing VITALS_WINDOW_DAYS window. A separate gem and scope from the
    # publisher API above.
    #
    # @param package_name [String, nil]
    # @return [VitalsResult] never raises for API/credential problems
    def fetch_vitals(package_name)
      package_name = package_name.to_s.strip
      return build_vitals(:no_package_name) if package_name.blank?
      return build_vitals(:not_configured, package_name: package_name) unless @credential

      require 'google/apis/playdeveloperreporting_v1beta1'
      read_vitals(package_name)
    rescue LoadError => e
      # The reporting gem not being installed is the common case: it is a separate
      # dependency from the publisher gem, so this read degrades on its own.
      build_vitals(:error, package_name: package_name, detail: "#{e.class} #{e.message}")
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
      code, detail = play_error(e)
      build(code, package_name: package_name, detail: detail)
    rescue StandardError => e
      # A bad service-account key surfaces as Signet::AuthorizationError, which
      # is not guaranteed to be loaded, so it is matched by name (as preflight does).
      build(signet_or_error(e), package_name: package_name, detail: "#{e.class} #{e.message}")
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

    def read_reviews(package_name, translation_language)
      @credential.with_credentials_file do |creds_path|
        client = build_client(creds_path)
        response = client.list_reviews(
          package_name,
          max_results: REVIEWS_PAGE_SIZE,
          translation_language: translation_language.presence
        )
        build_reviews(:ok, package_name: package_name, reviews: map_reviews(response))
      end
    rescue Google::Apis::AuthorizationError => e
      build_reviews(:auth_failed, package_name: package_name, detail: e.message)
    rescue Google::Apis::ClientError => e
      code, detail = play_error(e)
      build_reviews(code, package_name: package_name, detail: detail)
    rescue StandardError => e
      build_reviews(signet_or_error(e), package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    def map_reviews(response)
      Array(response&.reviews).map do |review|
        comment = Array(review.comments).find { |c| c.user_comment } || Array(review.comments).first
        user = comment&.user_comment
        developer = comment&.developer_comment
        ReviewInfo.new(
          review_id: review.review_id,
          author_name: review.author_name,
          rating: user&.star_rating,
          text: user&.text.presence || user&.original_text,
          language: user&.reviewer_language,
          device: user&.device,
          app_version_name: user&.app_version_name,
          last_modified: parse_play_time(user&.last_modified),
          developer_reply: developer&.text.presence,
          thumbs_up: user&.thumbs_up_count,
          thumbs_down: user&.thumbs_down_count,
          replied_at: parse_play_time(developer&.last_modified)
        )
      end
    end

    def read_vitals(package_name)
      @credential.with_credentials_file do |creds_path|
        client = build_reporting_client(creds_path)
        window = vitals_timeline
        vitals = VITALS_FEATURES.flat_map do |feature|
          map_vitals(feature, query_vital(client, feature, package_name, window))
        end
        build_vitals(:ok, package_name: package_name, vitals: vitals, window: window)
      end
    rescue Google::Apis::AuthorizationError => e
      build_vitals(:auth_failed, package_name: package_name, detail: e.message)
    rescue Google::Apis::ClientError => e
      code, detail = play_error(e)
      build_vitals(code, package_name: package_name, detail: detail)
    rescue StandardError => e
      build_vitals(signet_or_error(e), package_name: package_name, detail: "#{e.class} #{e.message}")
    end

    # Each vitals feature is a metric set with its own query method and request
    # class; a mismatch (a gem older than the feature) is a miss, not a NoMethodError.
    def query_vital(client, feature, package_name, window)
      method = QUERY_METHODS[feature]
      request_class = request_for(feature)
      return nil unless method && request_class && client.respond_to?(method)

      client.public_send(
        method,
        "apps/#{package_name}/#{metric_set(feature)}",
        request_class.new(metrics: [feature, DISTINCT_USERS], timeline_spec: window)
      )
    end

    def request_for(feature)
      mod = Google::Apis::PlaydeveloperreportingV1beta1
      case feature
      when 'crashRate' then mod::GooglePlayDeveloperReportingV1beta1QueryCrashRateMetricSetRequest
      when 'anrRate' then mod::GooglePlayDeveloperReportingV1beta1QueryAnrRateMetricSetRequest
      end
    end

    def metric_set(feature)
      QUERY_METHODS.key?(feature) ? "#{feature}MetricSet" : nil
    end

    def map_vitals(feature, response)
      Array(response&.rows).first(VITALS_MAX_ROWS).map do |row|
        rate = Array(row.metrics).find { |m| m.metric == feature }
        users = Array(row.metrics).find { |m| m.metric == DISTINCT_USERS }
        VitalInfo.new(
          kind: feature,
          start_time: date_time(row.start_time),
          aggregation_period: row.aggregation_period,
          # A row with no rate reads as "not measured", not 0 crashes.
          value: rate&.decimal_value&.value,
          user_count: users&.decimal_value&.value
        )
      end
    end

    # The trailing window as a TimelineSpec of civil DateTimes. A TimeZone with an
    # id is the documented shape; the day/hour fields are what the API reads.
    def vitals_timeline
      mod = Google::Apis::PlaydeveloperreportingV1beta1
      spec = mod::GooglePlayDeveloperReportingV1beta1TimelineSpec.new(
        aggregation_period: 'DAILY',
        start_time: date_time_from(VITALS_WINDOW_DAYS.days.ago),
        end_time: date_time_from(Time.current)
      )
      spec
    end

    def date_time_from(time)
      mod = Google::Apis::PlaydeveloperreportingV1beta1
      utc = time.utc
      mod::GoogleTypeDateTime.new(
        year: utc.year, month: utc.month, day: utc.day,
        hours: utc.hour, minutes: utc.min, seconds: utc.sec,
        time_zone: mod::GoogleTypeTimeZone.new(id: 'UTC')
      )
    end

    def date_time(value)
      return nil if value.nil?

      format('%04d-%02d-%02d', value.year, value.month, value.day)
    end

    # Play timestamps are {seconds, nanos} objects; the caller only needs the date.
    def parse_play_time(value)
      seconds = value&.seconds
      return nil if seconds.nil?

      Time.zone.at(seconds).to_date
    rescue StandardError
      nil
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

    # The Reporting API is a separate service (see REPORTING_SCOPE), so it gets its
    # own client rather than sharing the publisher one.
    def build_reporting_client(creds_path)
      client = Google::Apis::PlaydeveloperreportingV1beta1::PlaydeveloperreportingService.new
      client.authorization = Google::Auth::ServiceAccountCredentials.make_creds(
        json_key_io: File.open(creds_path),
        scope: REPORTING_SCOPE
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
        message: message_for(code, context: :listing, package_name: package_name, detail: detail)
      )
    end

    def build_reviews(code, package_name: nil, reviews: nil, detail: nil)
      ReviewsResult.new(
        code: code,
        package_name: package_name,
        reviews: reviews,
        message: message_for(code, context: :reviews, package_name: package_name, detail: detail)
      )
    end

    def build_vitals(code, package_name: nil, vitals: nil, window: nil, detail: nil)
      VitalsResult.new(
        code: code,
        package_name: package_name,
        vitals: vitals,
        window: window,
        message: message_for(code, context: :vitals, package_name: package_name, detail: detail)
      )
    end

    # The shared mapping of a Google client error to a Result code and the detail
    # kept for it. 404/403 have fixed messages, so their raw text is dropped; any
    # other status keeps Google's message, which is the only clue to what went wrong.
    def play_error(exception)
      code = case exception.status_code
             when 404 then :package_not_found
             when 403 then :access_denied
             else :error
             end
      [ code, (%i[package_not_found access_denied].include?(code) ? nil : exception.message) ]
    end

    # A bad service-account key surfaces as Signet::AuthorizationError, which is not
    # guaranteed to be loaded, so it is matched by name (as preflight does).
    def signet_or_error(exception)
      exception.class.name.to_s.start_with?('Signet::') ? :auth_failed : :error
    end

    # Stored/shown in the site locale, the same way PlayPreflightService writes
    # its messages. Reviews and vitals get their own `no_package_name` /
    # `package_not_found` wording (the listing's tells the publisher to upload a
    # bundle, which is not the fix for a reviews read); every other code is shared.
    def message_for(code, context:, package_name:, detail:)
      I18n.with_locale(Setting.site_locale) do
        key = "admin.play_import.messages.#{context}.#{code}"
        key = "admin.play_import.messages.#{code}" unless I18n.exists?(key)
        I18n.t(key, package: package_name, email: @credential&.service_account_email, detail: detail)
      end
    end
  end
end
