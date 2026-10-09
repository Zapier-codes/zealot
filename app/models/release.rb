# frozen_string_literal: true

require 'digest'

class Release < ApplicationRecord
  # Task 40i-b: set ONLY by ReleaseUploadReleaseBuilder (the manual-upload tripwire spec pins that), to 'apk' or
  # 'aab', on a release built from CI's stage-1 report of a staged upload. Such a release has no mounted file:
  # its bytes are in the staging bucket until CI's second stage moves them to the storage repo (40i-c). The flag
  # is not a column and does not survive a reload; it only tells this one save which checks and hooks apply.
  attr_accessor :storage_intake_kind

  def storage_intake?
    storage_intake_kind.present?
  end

  after_commit :schedule_proxy_injection, on: :create
  def schedule_proxy_injection
    # Task 40i-b: SDK injection for a staged upload runs in CI (40j), never on a file Render does not hold.
    return if storage_intake?

    ProxySdkInjectionJob.perform_later(self.id)
  end

  # Task 27c: see the after_create registration above.
  def publish_catalog_index_if_app_live
    return unless app.listing_live?

    CatalogIndexPublishJob.enqueue_for(app.tenant)
  end

  # Task 27f-d: true when the save changed a column the index publishes per version. Read from
  # `saved_changes` (not `saved_change_to_<column>?` per name) so the list lives in one constant.
  def catalog_index_release_field_changed?
    (saved_changes.keys & CATALOG_INDEX_RELEASE_FIELDS).any?
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
    # Task 40i-b: a staged upload is created held and cannot be installed yet; 40i-c sends this email when CI
    # has finished and the release becomes available, so members are not told about a build with no file.
    return if storage_intake?
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

  # Task 19e: every destroy path (manual delete, bulk channel delete, the
  # dependent: :destroy cascade from App/Scheme/Channel, demo mode's
  # App.destroy_all) ends up calling #destroy on each release, so one
  # after_destroy_commit here covers all of them. Runs after commit, and the
  # job is best-effort, so a storage hiccup never blocks or rolls back a
  # delete the user already asked for.
  after_destroy_commit :enqueue_storage_cleanup

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

  # Task 32a: staged rollout (see AddStagedRolloutToReleases for why this is
  # a separate concept from the 27f-owned `status` enum). `active` is the
  # steady ramping state; `complete` means the percentage no longer matters
  # (everyone gets it -- set automatically once percentage hits 100, see
  # #sync_rollout_status_with_percentage below, or settable directly by an
  # admin who wants to skip the ramp); `halted` freezes the current
  # percentage without changing it, the same "pause, don't undo" behavior
  # Play's own halt control has.
  enum :rollout_status, {
    active: 'active',
    halted: 'halted',
    complete: 'complete'
  }, prefix: :rollout

  # Task 27f-a: the release's lifecycle in our own store (see AddStatusToReleases). `held` is kept
  # out of the signed index until it is released; `halted` and `pulled` stay in it so a store
  # client can stop offering them. Separate from `rollout_status` (the staged-rollout ramp) and
  # from the Play publish states above.
  enum :status, {
    available: 'available',
    held: 'held',
    halted: 'halted',
    pulled: 'pulled'
  }, prefix: true

  # Task 40a: where the release's CI compile stands (see AddCiCompileToReleases). NULL means the
  # release was never sent to CI. `Api::CiCompileController#callback` (40a) records the result and
  # `CiCompileDispatchJob` (40b) sets `queued`/`dispatched`; since 40d the upload hook calls it for an AAB
  # while `CI_COMPILE_ENABLED=true`. Since 40e, `done` (with the universal APK recorded) is what
  # `serves_universal_apk?` reads to serve and index the release.
  enum :ci_compile_state, {
    queued: 'queued',
    dispatched: 'dispatched',
    done: 'done',
    failed: 'failed'
  }, prefix: :ci_compile

  # Task 30 (D-Store leaf 7.a.vi.zi): the outcome of the compile that turns an AAB into signed APKs,
  # recorded on every path of `AnthropicAssetDeliveryJob` (and by `Api::CiCompileController` for the CI
  # path) so "still running" (NULL), "finished" (done), "nothing to do" (skipped) and "failed" are told
  # apart. `asset_delivery_error` carries a short, safe reason and never a path or a secret. Distinct
  # from `ci_compile_state`, which tracks the CI dispatch itself.
  enum :asset_delivery_state, {
    pending: 'pending',
    done: 'done',
    skipped: 'skipped',
    failed: 'failed'
  }, prefix: :asset_delivery

  # Task 27f-b: which status a release may move to from each status, and the name of the console
  # action for that move (`releases.show.status_actions.<name>`). One table drives both the buttons
  # on the release page and the server-side check in `ReleasesController#update_status`, so a
  # crafted request cannot make a move the page would not offer. `held` can only be entered from
  # `available` (Play's managed publishing holds a release before it goes out) and `pulled` can
  # only go back to `available`; a halt is "pause, don't undo", so it resumes to `available`.
  STATUS_TRANSITIONS = {
    'available' => { 'held' => 'hold', 'halted' => 'halt', 'pulled' => 'pull' },
    'held' => { 'available' => 'release', 'pulled' => 'pull' },
    'halted' => { 'available' => 'resume', 'pulled' => 'pull' },
    'pulled' => { 'available' => 'restore' }
  }.freeze

  # The moves offered from the current status, as `{ target_status => action_name }`.
  #
  # Task 49: `hold` is offered only while the release may still be held (see `hold_allowed?`), so the
  # console button, the API's `release` check and `status_change_allowed?` all read the same rule.
  def status_actions
    actions = STATUS_TRANSITIONS.fetch(status.to_s, {})
    return actions unless actions.key?('held') && !hold_allowed?

    actions.except('held')
  end

  # Task 49: the one rule for holding a release, used by every door (the staged finisher, the API upload,
  # the console's `hold` move and the model's own validation). Only the FIRST release of an app may be
  # held (an owner who wants to check it before it goes out, the way Play's managed publishing does).
  # An update to an app that already has a version is never held: a held update leaves everyone who
  # visits the website or the store on the old version until someone notices, which is what happened to
  # release 7 of Appstore. Taking a bad update away stays possible with `halt` and `pull`, which keep it
  # in the index so a store client can stop offering it.
  def first_release_of_app?
    app_id = app&.id
    return true if app_id.nil?

    others = Release.joins(channel: :scheme).where(schemes: { app_id: app_id })
    others = others.where.not(id: id) if persisted?
    !others.exists?
  end
  alias hold_allowed? first_release_of_app?

  # Task 49: the model-level guard behind `status_actions`, so a console edit, a rake task or any other
  # writer that bypasses the transition table cannot hold an update either. Creating a release `held`
  # is not an update and is untouched (the staged builder always starts a release held and the
  # finisher then releases it).
  def update_cannot_be_held
    return unless will_save_change_to_status? && status_held?
    return if hold_allowed?

    errors.add(:status, I18n.t('releases.messages.errors.update_cannot_be_held',
                               default: 'An update to an app that already has a version cannot be held; ' \
                                        'halt or pull it instead.'))
  end

  def status_change_allowed?(target)
    status_actions.key?(target.to_s)
  end

  belongs_to :channel
  belongs_to :play_approved_by, class_name: 'User', optional: true
  belongs_to :play_rejected_by, class_name: 'User', optional: true
  has_one :metadata, class_name: 'Metadatum', dependent: :destroy
  has_and_belongs_to_many :devices, dependent: :destroy

  # Task 37b-iii-s7a: the releases that belong to one tenant's catalog, i.e. the releases of the
  # apps `App.for_tenant` returns (release -> channel -> scheme -> app). It reads through
  # `App.for_tenant` on purpose so the two can never disagree about what "the default tenant"
  # or "an unknown tenant" means. Currently used only by the public landing count.
  scope :for_tenant, ->(tenant) {
    joins(channel: :scheme).where(schemes: { app_id: App.for_tenant(tenant).select(:id) })
  }

  validates :file, presence: true, on: :create, unless: :storage_intake?
  validates :rollout_percentage, numericality: {
    only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 100
  }
  validate :update_cannot_be_held, on: :update
  validate :manifest_readable, on: :create
  validate :bundle_id_matched, on: :create
  validate :determine_file_exist, on: :create
  validate :play_target_bundle_valid, on: :create, if: :play_store_target?

  before_save :sync_rollout_status_with_percentage, if: :rollout_percentage_changed?

  # Reaching 100 always means "done ramping," regardless of how it got
  # there (an admin dragging the slider up, or setting it to 100 directly).
  # Does not fight an explicit halt: an admin who halts *at* 100 (freezing a
  # release that was already fully rolled out, e.g. ahead of investigating a
  # late-arriving report) stays halted rather than being silently flipped
  # back to complete.
  def sync_rollout_status_with_percentage
    self.rollout_status = 'complete' if rollout_percentage == 100 && !rollout_halted?
  end

  # Deterministic, sticky device bucketing -- same reference algorithm the
  # design note this leaf implements is based on: bucket = first 8 bytes of
  # sha256("device_id:release_id") as a big-endian uint64, mod 100. Using
  # this release's own id as the seed (rather than a separately-stored
  # random seed) keeps the bucket reproducible from data Zealot already has
  # for every release, with no extra column, while still being
  # release-specific -- the same device lands in a different bucket for a
  # different release, so being "in" one rollout says nothing about being
  # "in" the next one.
  def rollout_includes_device?(device_id)
    return true if rollout_percentage >= 100
    return false if rollout_percentage <= 0 || device_id.blank?

    digest = Digest::SHA256.digest("#{device_id}:#{id}")
    bucket = digest.byteslice(0, 8).unpack1('Q>') % 100
    bucket < rollout_percentage
  end
  validate :play_version_code_newer, on: :create, if: :play_store_target?

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
  # Task 27c: a new release changes CatalogIndex::Serializer's versions[]
  # for this app (see App#catalog_releases, added in 29b for exactly this
  # list), so the next index has to be regenerated. Only matters for an app
  # already on the catalog -- CatalogIndex::Serializer.for_live_apps scopes
  # to App.listing_live, so a release on a draft/awaiting_payment/suspended
  # app doesn't change anything the index currently shows and would just be
  # a wasted publish.
  after_create  :publish_catalog_index_if_app_live
  # Task 27f-a: holding, releasing, halting or pulling a release changes what the index shows, so
  # it republishes the owning tenant's catalog like a new release does. Task 27f-d adds the two
  # rollout columns: the index carries `rollout` per version (`Serializer#rollout_for`), so a ramp
  # step or a halted rollout has to reach readers now, not at the next unrelated publish. One
  # callback with an OR condition, so a save that changes several of them still enqueues once.
  # Task 40e: the universal APK's hash and size are what the index advertises for a CI-built release, and
  # CI's result arrives after the entry first went out at upload time, so recording them republishes.
  # Task 46b: `permissions` is published per version too (Serializer), so setting them over the API
  # (PUT /api/releases/:id/permissions) has to reach readers, not wait for an unrelated publish.
  # Task 46b-index: `ci_compile_state` too, because the index lists a CI release only once its compile is done.
  CATALOG_INDEX_RELEASE_FIELDS = %w[
    status rollout_percentage rollout_status universal_apk_sha256 universal_apk_size permissions ci_compile_state
  ].freeze

  after_update_commit :publish_catalog_index_if_app_live, if: :catalog_index_release_field_changed?

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
    return universal_apk_size if serves_universal_apk?

    file&.size
  end
  alias_method :file_size, :size

  # Task 40e: true once CI has compiled this bundle and Zealot has recorded a complete, checkable result
  # (state `done`, the stored universal APK's key, its SHA-256 and a positive size). Such a release is
  # installed from that signed universal APK in storage, not from the bundle itself: a sideload store has
  # no Play-style split installer, and the catalog index must describe the bytes a reader actually gets
  # (D-Store and Storeapp verify the hash). All four values are required so a half-recorded result is
  # never advertised.
  def serves_universal_apk?
    ci_compile_done? && universal_apk_storage_key.present? && universal_apk_sha256.present? &&
      universal_apk_size.to_i.positive?
  end

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

  # Task 40e: a release also "has a file" when its bytes live only in storage (the CI-built universal APK,
  # or a mirrored primary file after a redeploy wiped the disk). Before, only the local file counted, so
  # every evicted release showed "missing file" and no install button. This answers the same question
  # `ReleaseDownload#available?` does (something is stored, or something is on disk).
  def file?
    return true if serves_universal_apk? || file_storage_key.present?
    return false if file.blank?

    File.exist?(file.path)
  end

  def file_extname
    # A CI-built release is served as its universal APK whatever the uploaded bundle was called.
    return '.apk' if serves_universal_apk?

    # Once the local copy is gone (ephemeral disk), the mirrored file's key
    # still carries the real extension, so download URLs don't turn into .zip.
    return File.extname(file_storage_key) if file_storage_key.present? && (file.blank? || !File.file?(file.path))
    return '.zip' if file.blank? || !File.file?(file&.path)

    File.extname(file.path)
  end

  # The cosmetic last segment of `/download/releases/:id/<name>`. Task 44c: `version_datetime` (the stored value
  # of the channel's `download_filename_type`, kept because it lives in a column and in the API) now means "name
  # and version": `appstore-1.1.4.apk`, no build number and no timestamp.
  def download_filename
    case channel.download_filename_type&.downcase&.to_sym
    when :version_datetime
      name_version_filename
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

  # D-Store leaf 7.a.ii.zi: an Android App Bundle whose manifest could not be read is refused,
  # not saved with a blank package name and version code (see ReleaseParser#manifest_unreadable_reason
  # for the reasons and for what is deliberately not covered). Runs before #bundle_id_matched, which
  # skips itself for the same upload so the cause is reported once.
  def manifest_readable
    reason = manifest_unreadable_reason
    return unless reason

    errors.add(:file, I18n.t('releases.messages.errors.manifest_unreadable', reason: reason))
  end

  def bundle_id_matched
    return if (file.blank? && !storage_intake?) || channel&.bundle_id.blank?
    return if manifest_unreadable_reason
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
    return if file.blank? && !storage_intake?

    expected = app.play_package_name
    if expected.blank? && bundle_id.present? && App.where(play_package_name: bundle_id).where.not(id: app.id).exists?
      errors.add(:play_store_target, I18n.t('releases.messages.errors.play_package_name_taken', got: bundle_id))
      return
    end

    return if expected.blank? || bundle_id.blank? || bundle_id == expected

    errors.add(:play_store_target, I18n.t('releases.messages.errors.play_package_name_mismatch',
                                          got: bundle_id, expect: expected))
  end

  # Task 23: an update on Play is a new bundle with a higher versionCode than
  # anything Google already has for the package (it replaces the previous
  # release on the track; it can't overwrite it). Refuse the upload up front
  # with a clear message instead of letting it fail at Google after admin
  # approval. build_version is the bundle's versionCode (the publish service
  # sends `build_version.to_i` as the version code).
  def play_version_code_newer
    return if file.blank? && !storage_intake?

    code = build_version.to_i
    return if code <= 0

    highest = app.highest_play_version_code
    return if highest.nil? || code > highest

    errors.add(:play_store_target, I18n.t('releases.messages.errors.play_version_code_not_newer',
                                          got: code, latest: highest))
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

  # Task 30: record the compile outcome, set on every path of `AnthropicAssetDeliveryJob` and by the CI
  # callback (`Api::CiCompileController`). `error` is truncated and must be safe to show (never a path or
  # a secret); a `done` or `skipped` write clears any earlier error. A missing record leaves the state
  # NULL, which is how a release the compile never reached is told apart from one it finished.
  def record_asset_delivery!(state, error: nil)
    update_columns(
      asset_delivery_state: state,
      asset_delivery_error: error.to_s.presence&.truncate(500),
      asset_delivery_state_at: Time.current
    )
  end

  private

  # The instance is frozen but still readable at this point (after_destroy
  # runs before Rails freezes it for writes, and after_commit callbacks still
  # see the in-memory attributes even though the row is gone), so the keys are
  # captured here and passed to the job rather than re-queried by id.
  def enqueue_storage_cleanup
    # Task 46c: the CI-built universal APK is the biggest object a release owns and was missing from this list, so
    # deleting a release left it behind in storage for good. Needed now that a new version replaces the old one.
    keys = [file_storage_key, patched_file_storage_key, compressed_apks_storage_key, icon_storage_key,
            universal_apk_storage_key].compact
    return if keys.empty?

    ReleaseStorageCleanupJob.perform_later(id, keys)
  end

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
    # Task 40i-b: a staged upload has no mounted file by design; the builder already has CI's report of it.
    return if storage_intake?

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
    return if bundle_for_play_check?

    self.play_store_target = false
    @play_target_dropped = true
  end

  # Task 40i-b: a staged upload says what it is in `storage_intake_kind`; every other release is judged by its
  # mounted file, exactly as before (a release with no file at all is left alone).
  def bundle_for_play_check?
    return storage_intake_kind == 'aab' if storage_intake?

    file.blank? || file.path.to_s.end_with?('.aab')
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
  # The one hook every AAB upload passes through (Task 39a pins `Release.upload_file` to two callers, both
  # of which save through here). Task 40d: with `CI_COMPILE_ENABLED=true` the bundle is compiled, split,
  # signed and compressed by the storage repo's workflow (`CiCompileDispatchJob`, which only mirrors the
  # file and dispatches) and Zealot never runs bundletool; there is deliberately NO local fallback. With it
  # off, the Ruby compile runs exactly as before. `AnthropicAssetDeliveryJob` itself refuses to run while CI
  # is on, so a job already queued or enqueued by hand cannot compile either.
  def anthropic_asset_delivery_job
    # Task 40i-b: a staged upload is compiled by the stage-2 workflow (40i-c), which also uploads the file to
    # storage; this hook's dispatch mirrors a LOCAL file, and there is none. Skipped here, not routed around.
    return if storage_intake?
    return unless file.path.to_s.end_with?('.aab')

    if CiCompileDispatcher.enabled?
      CiCompileDispatchJob.enqueue_for(self)
    else
      AnthropicAssetDeliveryJob.perform_later(id)
    end
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
    app.supersede_pending_play_releases!(except: self)
    request_play_approval!
    # Adopting a package name already schedules the check (App callback).
    AnthropicPlayPreflightJob.perform_later(app.id) if app.play_package_name.present? && !adopted
  end

  # Task 41d: the generic names a workflow older than Task 41 stored files under. They say nothing about the app,
  # so they are never offered as a download name.
  LEGACY_FIXED_STORED_NAMES = %w[universal.apk release.apks.br].freeze

  def original_filename
    # `file?` is also true for a release held only in storage, where there is no uploader identifier (and
    # for a CI-built release the served file is the universal APK, not the uploaded bundle's name). In both
    # cases the name the file was stored under is the name to offer (`Storeapp-1.1.4-218.apk`, Task 41).
    return stored_file_name || default_filename if serves_universal_apk? || file.blank?

    file? ? file.identifier : default_filename
  end

  # Task 41d: the last segment of the storage key the download is served from, as CI reported it: the universal
  # APK's key for a compiled release, else the primary file's. Nil when there is none or it is one of the old
  # generic names.
  def stored_file_name
    key = serves_universal_apk? ? universal_apk_storage_key : file_storage_key
    name = File.basename(key.to_s)
    return nil if name.blank? || name == '.' || LEGACY_FIXED_STORED_NAMES.include?(name)

    name
  end
  
  # Task 44c: the app's name and the version (`ReleaseArtifactName.for`), the same base the stored files carry,
  # then the extension. It used to be `<channel slug>_<version>_<build>_<YYYYMMDDHHMM>`.
  def name_version_filename
    ReleaseArtifactName.for(self) + file_extname
  end

  def default_filename
    name_version_filename
  end

  def recently_release_app_id
    app.id
  end
end
