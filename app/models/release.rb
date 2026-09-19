# frozen_string_literal: true

class Release < ApplicationRecord
  after_commit :schedule_proxy_injection, on: :create
  def schedule_proxy_injection
    ProxySdkInjectionJob.perform_later(self.id)
  end

  # Task 12 emails: "new build published" to the app's members, and a notice
  # when a Play Store publish fails. Both only enqueue a job (GoodJob) and
  # never block or fail the upload.
  after_commit :schedule_deploy_notification, on: :create
  after_commit :notify_play_publish_failed, on: :update,
               if: -> { saved_change_to_play_publish_status? && play_publish_failed? }
  after_commit :notify_play_publish_waiting, on: :update,
               if: -> { saved_change_to_play_publish_status? && play_publish_waiting_for_setup? }

  def schedule_deploy_notification
    return unless EmailNotifications.enabled?

    ReleaseDeployNotificationJob.perform_later(id)
  end

  def notify_play_publish_failed
    return unless EmailNotifications.enabled?

    I18n.with_locale(Setting.site_locale) do
      EmailBroadcastJob.perform_later(
        kind: 'notices',
        app_id: app.id,
        subject: I18n.t('notification_mailer.play_publish_failed.subject', app: app_name),
        body: I18n.t('notification_mailer.play_publish_failed.body', app: app_name,
                     error: play_publish_error.to_s.truncate(500))
      )
    end
  end

  # Task 18: the one manual step of the Play flow (the first bundle upload
  # of a new app in Play Console) needs someone with Play Console access,
  # which members submitting apps don't have — so the notice goes to the
  # admins, once, when a release starts waiting for it. Only fires on the
  # status change, so the automatic re-checks never repeat the email.
  def notify_play_publish_waiting
    return unless EmailNotifications.enabled?

    I18n.with_locale(Setting.site_locale) do
      EmailBroadcastJob.perform_later(
        kind: 'notices',
        app_id: app.id,
        admins_only: true,
        subject: I18n.t('notification_mailer.play_publish_waiting.subject', app: app_name),
        body: I18n.t('notification_mailer.play_publish_waiting.body', app: app_name,
                     detail: play_publish_error.to_s.truncate(800))
      )
    end
  end
  extend VersionCompare

  include ReleaseUrl
  include ReleaseAuth
  include ReleaseParser
  include RecentlyReleasesCacheable

  mount_uploader :file, AppFileUploader
  mount_uploader :icon, AppIconUploader

  scope :latest, -> { order(version: :desc).first }

  # Play Store publish-approval workflow (task #11 — bookkeeping only, see
  # handover.md's "Scope, stated plainly": a release marked play_store_target
  # is one this org intends to also push to Play Store, which per operator
  # decision needs explicit admin approval, auto-expiring after 48h if
  # nobody acts. This status never affects our own internal distribution —
  # a release is downloadable through Zealot itself the moment it's
  # uploaded, same as always, regardless of this status.
  enum :play_approval_status, {
    not_requested: 'not_requested',
    pending: 'pending',
    approved: 'approved',
    rejected: 'rejected',
    expired: 'expired'
  }, prefix: :play_approval

  scope :play_store_targeted, -> { where(play_store_target: true) }
  scope :awaiting_play_approval, -> { play_store_targeted.play_approval_pending }
  scope :play_approval_overdue, -> { play_approval_pending.where('play_approval_expires_at < ?', Time.current) }
  # Approved-or-further releases whose Play publish status is worth an
  # admin's attention — i.e. everything except the steady states of
  # "never targeted Play" (not_requested) or "sitting in the approval
  # queue" (still shown by awaiting_play_approval above). Used by the
  # play_approvals index to also surface publishing/published/failed
  # releases, not just ones still awaiting a yes/no.
  scope :play_publish_tracked, -> { play_store_targeted.where.not(play_approval_status: %i[not_requested pending]) }

  # Task #7: tracks the actual Play Developer API publish call, distinct
  # from play_approval_status above (which only tracks whether an admin
  # signed off — see AnthropicPlayPublishJob for what drives these
  # transitions). A release can be play_approval_approved but still
  # not_published (job hasn't run yet) or failed (needs a fix + retry).
  enum :play_publish_status, {
    not_published: 'not_published',
    publishing: 'publishing',
    published: 'published',
    failed: 'failed',
    # Task 18: approved, but Play Console itself isn't ready yet (first
    # bundle of a new app not uploaded yet). Not a failure:
    # resumes automatically once the preflight check passes.
    waiting_for_setup: 'waiting_for_setup'
  }, prefix: :play_publish

  belongs_to :channel
  belongs_to :play_approved_by, class_name: 'User', optional: true
  belongs_to :play_rejected_by, class_name: 'User', optional: true
  has_one :metadata, class_name: 'Metadatum', dependent: :destroy
  has_and_belongs_to_many :devices, dependent: :destroy

  validates :file, presence: true, on: :create
  validate :bundle_id_matched, on: :create
  validate :determine_file_exist, on: :create
  validate :play_target_bundle_valid, on: :create, if: :play_store_target?

  before_validation :drop_unsupported_play_target, on: :create
  before_validation :determine_disk_space
  before_create :auto_release_version
  before_create :default_source
  before_create :detect_device
  before_save   :convert_changelog
  before_save   :convert_custom_fields
  before_save   :strip_branch

  after_create  :retained_build_job
  after_create  :anthropic_asset_delivery_job
  after_create  :request_play_approval_if_targeted

  delegate :scheme, to: :channel
  delegate :app, to: :scheme

  paginates_per     50
  max_paginates_per 100

  def self.version_by_channel(channel_slug, release_id)
    channel = Channel.friendly.find(channel_slug)
    channel.releases.find(release_id)
  end

  # 上传 app
  def self.upload_file(params, parser: nil, source: 'web')
    Release.new(params) do |release|
      release.parse!(parser, source)
    end
  end

  def self.find_since_version(release_version, build_version)
    current_release = select(:id).find_by(
      release_version: release_version,
      build_version: build_version
    )

    prepared_releases = if current_release
      where('id > ?', current_release.id).order(id: :desc)
    else
      newer_versions = channel.release_versions.select { |version| ge_version(version, release_version) }
      where(elease_version: newer_versions,).order(id: :desc)
    end

    prepared_releases.select { |release|
      ge_version(release.release_version, release_version) &&
        gt_version(release.build_version, build_version)
    }
  end

  def app_name
    "#{app.name} #{scheme.name} #{channel.name}"
  end

  def native_codes(original: true)
    return unless native_codes = metadata&.native_codes
    return native_codes if original

    native_codes.each_with_object({}) do |code, obj|
      key = nil
      key = :x86 if code.include?('x86')
      key = :arm if code.include?('arm')
      key = :mips if code.include?('mips')
      key = riscv if code.include?('riscv')
      next unless key

      obj[key] ||= []
      obj[key] = code
    end
  end

  def size
    file&.size
  end
  alias_method :file_size, :size

  def short_git_commit
    return nil if git_commit.blank?

    git_commit[0..8]
  end

  def array_changelog(default_template: true)
    return empty_changelog(default_template) if changelog.blank?
    return [{'message' => changelog.to_s}] unless changelog.is_a?(Array) || changelog.is_a?(Hash)

    changelog
  end

  def text_changelog(default_template: true, head_line: false, field: 'message')
    array_changelog(default_template: default_template).each_with_object([]) do |line, obj|
      value = line[field]&.to_s || ''
      message = head_line ? value.split("\n")[0] : value
      obj << "- #{message}"
    end.join("\n")
  end

  def file?
    return false if file.blank?

    File.exist?(file.path)
  end

  def file_extname
    return '.zip' if file.blank? || !File.file?(file&.path)

    File.extname(file.path)
  end

  def download_filename
    case channel.download_filename_type&.downcase&.to_sym
    when :version_datetime
      version_datetime_filename
    when :original_filename
      original_filename
    else
      default_filename
    end
  end

  def empty_changelog(use_default_changelog = true)
    return [] unless use_default_changelog

    @empty_changelog ||= [{
      'message' => I18n.t('releases.messages.default_changelog')
    }]
  end

  def latest_version
    lastest = channel.releases.last
    return lastest if lastest.id > id
  end

  def bundle_id_matched
    return if file.blank? || channel&.bundle_id.blank?
    return if channel.bundle_id_matched?(self.bundle_id)

    message = I18n.t('releases.messages.errors.bundle_id_not_matched', got: self.bundle_id,
                                                                  expect: channel.bundle_id)
    errors.add(:file, message)
  end

  # Set by drop_unsupported_play_target; the controller uses it to tell the
  # uploader that the Play target was not applied.
  attr_reader :play_target_dropped

  # Task 18: Play only learns an app's applicationId from its first
  # uploaded bundle, so Zealot records the intended one on the App and
  # checks every Play-targeted release against it. When the bundle's
  # applicationId can't be read (bundle_id blank) there is nothing to
  # compare, so that case is let through rather than blocked.
  def play_target_bundle_valid
    return if file.blank?

    expected = app.play_package_name
    if expected.blank? && bundle_id.present? && App.where(play_package_name: bundle_id).where.not(id: app.id).exists?
      errors.add(:play_store_target, I18n.t('releases.messages.errors.play_package_name_taken', got: bundle_id))
      return
    end

    return if expected.blank? || bundle_id.blank? || bundle_id == expected

    errors.add(:play_store_target, I18n.t('releases.messages.errors.play_package_name_mismatch',
                                          got: bundle_id, expect: expected))
  end

  def perform_teardown_job(user_id, when_to_run: :later)
    case when_to_run
    when :later
      TeardownJob.perform_later(id, user_id)
    when :now
      TeardownJob.perform_now(id, user_id)
    end
  end

  def platform
    if ios?
      'iOS'
    elsif android?
      'Android'
    elsif harmonyos?
      'HarmonyOS'
    elsif mac?
      'macOS'
    elsif windows?
      'Windows'
    elsif linux?
      'Linux'
    else
      'Unknown'
    end
  end

  def ios?
    platform_type.casecmp?('ios') || platform_type.casecmp?('iphone') ||
    platform_type.casecmp?('ipad') || platform_type.casecmp?('universal') ||
    platform_type.casecmp?('appletv')
  end

  def android?
    platform_type.casecmp?('android') || platform_type.casecmp?('phone') ||
    platform_type.casecmp?('tablet') || platform_type.casecmp?('watch') ||
    platform_type.casecmp?('television') || platform_type.casecmp?('automotive')
  end

  def harmonyos?
    platform_type.casecmp?('harmonyos') || platform_type.casecmp?('default')
  end

  def mac?
    platform_type.casecmp?('macos')
  end

  def windows?
    platform_type.casecmp?('windows')
  end

  def linux?
    platform_type.casecmp?('linux') || platform_type.casecmp?('rpm') ||
    platform_type.casecmp?('deb')
  end

  # @return [Boolean, nil] expired true or false in get expoired_at, nil is unknown.
  def cert_expired?
    return unless ios?
    return unless expired_date = metadata&.mobileprovision&.fetch('expired_at', nil)

    (Time.parse(expired_date) - Time.now) <= 0
  end

  def debug_file
    debug_files = DebugFile.where(app: app, release_version: release_version, build_version: build_version)
    return if debug_files.blank?

    debug_files.select do |debug_file|
      if ios?
        debug_file.metadata.where("data->>'identifier' = ?", bundle_id).count > 0
      elsif android?
        debug_file.metadata.where(object: bundle_id).count > 0
      end
    end.first
  end

  # --- Play Store publish-approval workflow (task #11) ---------------------
  #
  # Bookkeeping only: none of this touches the actual Play Developer API
  # (that's task #7, still not started) and none of it ever removes a
  # release from our own internal distribution — it only tracks whether an
  # admin has signed off on *also* sending this particular release to Play
  # Store, with a 48h window before the request auto-expires back to
  # "internal distribution only" if nobody acts.

  PLAY_APPROVAL_WINDOW = 48.hours

  # Called automatically after create when play_store_target is set (see
  # #request_play_approval_if_targeted below). Exposed as a public method too
  # so a future UI action ("actually, also send this one to Play Store")
  # can re-request approval on a release that wasn't originally targeted,
  # without needing a whole new upload.
  def request_play_approval!
    update!(
      play_store_target: true,
      play_approval_status: :pending,
      play_approval_requested_at: Time.current,
      play_approval_expires_at: Time.current + PLAY_APPROVAL_WINDOW,
      play_approved_at: nil,
      play_approved_by: nil,
      play_rejected_at: nil,
      play_rejected_by: nil
    )
  end

  def approve_play_publish!(by)
    update!(
      play_approval_status: :approved,
      play_approved_at: Time.current,
      play_approved_by: by
    )

    # Task #7: this is the actual trigger for the Play Developer API
    # publish call — approval bookkeeping (task #11) alone never talks to
    # Google. See AnthropicPlayPublishJob for what happens if credentials
    # are missing or the call fails (play_publish_status flips to
    # `failed` with play_publish_error set; nothing here retries silently).
    AnthropicPlayPublishJob.perform_later(id)
  end

  # As of the play_rejected_at/play_rejected_by migration (fixing the gap
  # flagged since session 11), rejection has its own columns and no longer
  # touches play_approved_at/play_approved_by — those two now mean exactly
  # what their names say for every release reviewed from here on. Releases
  # rejected before this migration keep whatever play_approved_at/by value
  # was written under the old scheme; this method does not backfill history,
  # it only changes how new rejections are recorded.
  def reject_play_publish!(by)
    update!(
      play_approval_status: :rejected,
      play_rejected_at: Time.current,
      play_rejected_by: by
    )
  end

  # Called by AnthropicPlayApprovalExpiryJob's batch scan, not on a
  # per-release timer — see that job for why (same posture as
  # AnthropicMtprotoArchiveJob's batch-scan pattern per handover.md task
  # #11's notes). Deliberately does nothing to file/channel/distribution
  # state: expiry only ever affects whether this release is eligible for
  # Play Store publishing, never whether it's downloadable through Zealot.
  def expire_play_approval!
    update!(play_approval_status: :expired)
  end

  def play_approval_overdue?
    play_approval_pending? && play_approval_expires_at.present? && play_approval_expires_at < Time.current
  end

  private

  def platform_type
    @platform_type ||= (device_type || Channel.device_types[channel.device_type])
  end

  def auto_release_version
    latest_version = Release.where(channel: channel).limit(1).order(id: :desc).last
    self.version = latest_version ? (latest_version.version + 1) : 1
  end

  def convert_changelog
    if json_string?(changelog)
      self.changelog = JSON.parse(changelog)
    elsif changelog.blank?
      self.changelog = []
    elsif changelog.is_a?(String)
      hash = []
      changelog.split("\n").each do |message|
        next if message.blank?

        message = message[1..-1].strip if message.start_with?('-')
        hash << { message: message }
      end
      self.changelog = hash
    else
      self.changelog ||= []
    end
  end

  def convert_custom_fields
    if json_string?(custom_fields)
      self.custom_fields = JSON.parse(custom_fields)
    elsif custom_fields.blank?
      self.custom_fields = []
    else
      self.custom_fields ||= []
    end
  end

  def detect_device
    self.device_type ||= Channel.device_types[channel.device_type]
  end

  def determine_file_exist
    if self.file&.path.blank?
      errors.add(:file, :invalid)
    end
  end

  # Only an Android App Bundle (.aab) can go to Google Play; .apk and every
  # other file type is not supported there. That must never stop the build
  # from being uploaded and distributed through our own stores, so instead of
  # failing the upload the Play target is switched off and the controller
  # shows a "not supported" message (see #play_target_dropped).
  def drop_unsupported_play_target
    return unless play_store_target?
    return if file.blank? || file.path.to_s.end_with?('.aab')

    self.play_store_target = false
    @play_target_dropped = true
  end

  def determine_disk_space
    upload_path = Sys::Filesystem.stat(Rails.root.join('public/uploads'))
    disk_free_size = upload_path.bytes_free
    file_size = self&.file&.size || 0

    if disk_free_size <= file_size
      disk_free_human = ActiveSupport::NumberHelper.number_to_human_size(disk_free_size)
      file_size_human = ActiveSupport::NumberHelper.number_to_human_size(file_size)
      errors.add(:file, :not_enough_space, disk_free: disk_free_human, file_size: file_size_human)
    end
  rescue
    # do nothing
  end

  ORIGIN_PREFIX = 'origin/'
  def strip_branch
    return if branch.blank?
    return unless branch.start_with?(ORIGIN_PREFIX)

    self.branch = branch[ORIGIN_PREFIX.length..-1]
  end

  def default_source
    self.source ||= 'API'
  end

  def json_string?(value)
    JSON.parse(value)
    true
  rescue
    false
  end

  def enabled_validate_bundle_id?
    bundle_id = channel.bundle_id
    !(bundle_id.blank? || bundle_id == '*')
  end

  def retained_build_job
    RetainedBuildsJob.perform_later(channel)
  end

  # Only relevant for Android App Bundles; no-op for APK/IPA uploads.
  # The job itself also re-checks the config flag and file extension so
  # this stays safe even if called from elsewhere.
  def anthropic_asset_delivery_job
    return unless file.path.to_s.end_with?('.aab')

    AnthropicAssetDeliveryJob.perform_later(id)
  end

  # Only fires when the uploader explicitly flagged this release as bound
  # for Play Store (see releases/_form.html.slim's play_store_target
  # checkbox). Everything else about the release proceeds identically
  # either way — this only starts the 48h admin-approval clock.
  #
  # Task 18: also adopts the bundle's applicationId as the App's Play
  # package name when none was entered (the first Play-targeted AAB fixes
  # it, as it does in Play Console), and kicks off the Play-side setup
  # check so a missing manual step is known before an admin approves.
  def request_play_approval_if_targeted
    return unless play_store_target?

    adopted = app.adopt_play_package_name!(bundle_id)
    request_play_approval!
    # Adopting a package name already schedules the check (App callback).
    AnthropicPlayPreflightJob.perform_later(app.id) if app.play_package_name.present? && !adopted
  end

  def original_filename
    file? ? file.identifier : default_filename
  end
  
  def version_datetime_filename
    [
      channel.slug, release_version, build_version, created_at.strftime('%Y%m%d%H%M')
    ].join('_') + file_extname
  end

  def default_filename
    version_datetime_filename
  end

  def recently_release_app_id
    app.id
  end
end
