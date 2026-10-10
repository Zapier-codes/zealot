# frozen_string_literal: true

module ReleaseChecks
  # Z-P2/Z-P3/Z-P4 (Play Console parity): the automated review runner. Play pre-checks an upload and shows a
  # verdict before a person looks; this is Zealot's equivalent. It is deliberately split in two halves:
  #
  #   * `call` -- PURE. Given a release and an optional list of detected trackers, it runs the static checks
  #     Zealot already has data for and returns a Result (verdict + reasons + trackers). No writes, no I/O,
  #     so it is fully testable and a caller can preview a verdict.
  #   * `record!` -- writes that Result onto the release columns (Z-P3 surfaces it in the Console).
  #
  # The trackers come from the MobSF runner (Z-P4, `MobsfClient`); a caller that has no scanner passes none
  # and the static half still runs. The verdict is the worst reason's severity: any `reject` -> reject, else
  # any `flag` -> flag, else pass. Nothing here blocks a release from distribution -- Play shows the verdict
  # and a person decides; Zealot keeps the same rule (see the class comment on Release#play_approval_status).
  class AutomatedReview
    Reason = Struct.new(:code, :message, :severity, keyword_init: true)
    Result = Struct.new(:verdict, :reasons, :trackers, keyword_init: true) do
      def pass?  = verdict == 'pass'
      def flag?  = verdict == 'flag'
      def reject? = verdict == 'reject'
    end

    # The permissions Google classes as dangerous/run-time, plus a couple of Play-sensitive ones. A newly
    # added one on an update is what Play's review calls out, so it is a flag here too.
    SENSITIVE_PERMISSIONS = %w[
      android.permission.CAMERA
      android.permission.RECORD_AUDIO
      android.permission.ACCESS_FINE_LOCATION
      android.permission.ACCESS_COARSE_LOCATION
      android.permission.ACCESS_BACKGROUND_LOCATION
      android.permission.READ_CONTACTS
      android.permission.WRITE_CONTACTS
      android.permission.READ_CALL_LOG
      android.permission.WRITE_CALL_LOG
      android.permission.READ_SMS
      android.permission.SEND_SMS
      android.permission.RECEIVE_SMS
      android.permission.READ_PHONE_STATE
      android.permission.READ_PHONE_NUMBERS
      android.permission.CALL_PHONE
      android.permission.READ_EXTERNAL_STORAGE
      android.permission.WRITE_EXTERNAL_STORAGE
      android.permission.MANAGE_EXTERNAL_STORAGE
      android.permission.BODY_SENSORS
      android.permission.ACTIVITY_RECOGNITION
      android.permission.REQUEST_INSTALL_PACKAGES
      android.permission.SYSTEM_ALERT_WINDOW
      android.permission.QUERY_ALL_PACKAGES
      android.permission.POST_NOTIFICATIONS
    ].freeze

    # Play's minimum target API for new apps is a moving bar; keep it as one named constant so it moves in
    # one place. Anything below is a flag (it will not be publishable), not a hard reject -- an internal
    # build can still be distributed by Zealot itself.
    MIN_TARGET_SDK = 34

    def self.call(release, trackers: [], previous_permissions: nil)
      new(release, trackers: trackers, previous_permissions: previous_permissions).call
    end

    def initialize(release, trackers: [], previous_permissions: nil)
      @release = release
      @trackers = Array(trackers)
      @previous_permissions = previous_permissions
    end

    def call
      reasons = []
      reasons.concat(permission_reasons)
      reasons.concat(sdk_reasons)
      reasons.concat(tracker_reasons)
      reasons.concat(signature_reasons)

      Result.new(verdict: verdict_for(reasons), reasons: reasons, trackers: normalized_trackers)
    end

    # Writes the result onto the release (columns from migration 20261010090000). `status:` lets the job mark
    # `running` before a scan that may take a while, and `failed` when the scanner itself broke.
    def record!(status: 'done', result: nil)
      result ||= call
      @release.update_columns(
        automated_review_status: status,
        automated_review_verdict: result&.verdict,
        automated_review_reasons: (result ? result.reasons.map { |r| { 'code' => r.code, 'message' => r.message, 'severity' => r.severity } } : []),
        automated_review_trackers: (result ? result.trackers.map { |t| { 'name' => t.name, 'category' => t.category, 'code_signature' => t.code_signature } } : []),
        automated_reviewed_at: Time.current
      )
    end

    private

    def permission_reasons
      added = if @previous_permissions
                ReleaseChecks::PermissionDiff.between(@previous_permissions, @release.permissions).first
              else
                []
              end
      sensitive = added & SENSITIVE_PERMISSIONS
      return [] if sensitive.empty?

      [Reason.new(code: 'sensitive_permission_added', severity: 'flag',
                  message: "New sensitive permissions: #{sensitive.join(', ')}")]
    end

    def sdk_reasons
      reasons = []
      target = @release.respond_to?(:target_sdk_version) ? @release.target_sdk_version.to_i : 0
      if target.positive? && target < MIN_TARGET_SDK
        reasons << Reason.new(code: 'target_sdk_below_play_minimum', severity: 'flag',
                              message: "Target API #{target} is below the current minimum (#{MIN_TARGET_SDK}).")
      end
      reasons
    end

    def tracker_reasons
      return [] if normalized_trackers.empty?

      names = normalized_trackers.map(&:name)
      [Reason.new(code: 'third_party_trackers', severity: 'flag',
                  message: "Build ships third-party SDKs/trackers: #{names.join(', ')}")]
    end

    def signature_reasons
      checksum = @release.respond_to?(:signing_key_checksum) ? @release.signing_key_checksum.to_s : ''
      return [] unless checksum.strip.empty?

      [Reason.new(code: 'unsigned_apk', severity: 'reject',
                  message: 'The build has no signing-key checksum; it cannot be trusted as the developer’s.')]
    end

    def normalized_trackers
      @normalized_trackers ||= @trackers.filter_map do |t|
        name = t.respond_to?(:name) ? t.name.to_s.strip : nil
        next if name.nil? || name.empty?

        MobsfClient::Tracker.new(name: name,
                                 category: t.respond_to?(:category) ? t.category : nil,
                                 code_signature: t.respond_to?(:code_signature) ? t.code_signature : nil)
      end
    end

    def verdict_for(reasons)
      return 'reject' if reasons.any? { |r| r.severity == 'reject' }
      return 'flag' if reasons.any? { |r| r.severity == 'flag' }

      'pass'
    end
  end
end
