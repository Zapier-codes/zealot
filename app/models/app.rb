# frozen_string_literal: true

class App < ApplicationRecord
  include RecentlyReleasesCacheable

  # default_scope { order(id: :asc) }

  has_and_belongs_to_many :users
  has_many :collaborators, dependent: :destroy
  has_many :schemes, dependent: :destroy
  has_many :debug_files, dependent: :destroy

  scope :all_names, -> { all.map { |c| [c.name, c.id] } }
  scope :debug_files, -> { joins(:debug_files).distinct }
  scope :search_by_name, ->(query) {
    query.present? ? where("name ILIKE ?", "%#{query}%") : all
  }
  scope :sort_by_name, ->(query) {
    direction = %w[asc desc].include?(query&.downcase) ? query.upcase : "ASC"
    order(name: direction.downcase.to_sym)
  }
  scope :archived, -> { where(archived: true) }
  scope :active, -> { where(archived: false).or(where(archived: nil)) }

  validates :name, presence: true

  # Task 18 — Google Play only learns an app's applicationId from the first
  # bundle uploaded to Play Console (it is not a "create app" field there),
  # so the intended one is recorded here, verified against every
  # Play-targeted AAB (Release#play_target_bundle_valid) and, when left
  # blank, adopted from the first such AAB. `play_setup_status` is the
  # result of the last automated Play-side check
  # (Anthropic::PlayPreflightService).
  PLAY_PACKAGE_NAME_FORMAT = /\A[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+\z/

  enum :play_setup_status, {
    unchecked: 'unchecked',
    ready: 'ready',
    needs_first_upload: 'needs_first_upload',
    needs_access: 'needs_access',
    needs_credentials: 'needs_credentials',
    check_failed: 'check_failed'
  }, prefix: :play_setup

  before_validation :normalize_play_package_name
  validate :play_package_name_format_valid
  validates :play_package_name, uniqueness: true, allow_nil: true

  after_commit :schedule_play_preflight,
               if: -> { saved_change_to_play_package_name? && play_package_name.present? }
  after_destroy :delete_app_recently_releases_cache

  def channel_ids
    return unless schcmes_ids = schemes.select(:id).map(&:id)
    return unless channel_ids = Channel.select(:id).where(scheme: schcmes_ids).map(&:id)

    channel_ids
  end

  def recently_release
    Rails.cache.fetch(recently_release_cache_key, expires_in: 5.minutes) do
      return unless channel_ids
      return unless release = Release.where(channel: channel_ids).last

      release
    end
  end

  def total_schemes
    schemes.size
  end

  def total_channels
    schemes.all.sum { |s| s.channels.size }
  end

  def total_releases
    schemes.all.sum do |scheme|
      scheme.channels.all.sum do |channel|
        channel.releases.size
      end
    end
  end

  def total_debug_files
    debug_files.count
  end

  def android_debug_files
    debug_files.where(device_type: 'Android')
  end

  def ios_debug_files
    debug_files.where(device_type: 'iOS')
  end

  # Fetch all bundle id of iOS app
  def bundle_ids
    all_idenfiters(device_type: 'iOS')[:ios]
  end

  # Fetch all bundle id of iOS app
  def package_names
    all_idenfiters(device_type: 'Android')[:android]
  end

  def all_idenfiters(device_type: nil)
    schemes.all.each_with_object({}) do |scheme, obj|
      channels = scheme.channels
      channels = device_type ? channels.where(device_type: device_type) : channels.all
      channels.each do |channel|
        device_type = channel.device_type.to_sym
        obj[device_type] ||= []
        channel.releases.select(:bundle_id).distinct.each do |release|
          next if obj[device_type].include?(release.bundle_id)

          obj[device_type] << release.bundle_id
        end
      end
    end
  end

  def owner
    collaborators.find_by(owner: true)
  end

  def create_owner(user)
    collaborators.create(
      user: user,
      role: Collaborator.roles[:admin],
      owner: true
    )
  end

  def collaborator_user_ids
    collaborators.select(:user_id).map(&:user_id)
  end

  # Adopts a Play-targeted AAB's applicationId as this app's Play package
  # name when none was entered. Never overwrites an existing value (that
  # mismatch is rejected at upload instead). Returns true when it changed.
  def adopt_play_package_name!(value)
    value = value.to_s.strip
    return false if play_package_name.present? || value.blank?

    update(play_package_name: value)
  end

  # Stores an Anthropic::PlayPreflightService::Result. update_columns on
  # purpose: recording a check must not re-trigger the callbacks that
  # schedule a check.
  def record_play_setup!(result)
    update_columns(
      play_setup_status: result.app_status.to_s,
      play_setup_message: result.message,
      play_setup_checked_at: Time.current
    )
  end

  # All releases of this app, across its schemes and channels.
  def play_releases_scope
    Release.where(channel_id: Channel.where(scheme_id: schemes.select(:id)).select(:id))
  end

  # Task 23: every Play-targeted release of an app goes to the same Play
  # package and track (play_package_name / play_publish_track live on the App),
  # so they form one update line. Google only accepts a bundle whose
  # versionCode is higher than every one already uploaded, so the highest
  # versionCode that an admin approved and that hasn't failed (published,
  # publishing, or waiting for Play setup) is what a new Play-targeted upload
  # has to beat. Requests still *pending* don't count — a new upload replaces
  # them (see supersede_pending_play_releases!), which is what lets the owner
  # re-upload a fixed build under the same versionCode before approval.
  # Rejected, expired and failed ones never (fully) reached Google — an edit
  # is not partially applied. nil when there is none.
  def highest_play_version_code
    play_releases_scope
      .play_store_targeted
      .play_approval_approved
      .where.not(play_publish_status: 'failed')
      .pluck(:build_version)
      .map(&:to_i)
      .max
  end

  # Task 23: a newer Play-targeted upload replaces the older request that is
  # still waiting for admin approval, as a newer build replaces an older one
  # in a Play track. Otherwise the older one could be approved later and
  # published *after* (or fail against) the newer one. Uses `expired` — the
  # existing "no longer eligible" state that already drops a release out of the
  # approval queue — and never touches our own distribution of the build.
  def supersede_pending_play_releases!(except:)
    play_releases_scope.play_approval_pending
                       .where.not(id: except.id)
                       .update_all(play_approval_status: 'expired', updated_at: Time.current)
  end

  # Approved releases parked by AnthropicPlayPublishJob as
  # `waiting_for_setup`, oldest first.
  def waiting_play_releases
    Release.where(channel_id: Channel.where(scheme_id: schemes.select(:id)).select(:id))
           .play_approval_approved
           .play_publish_waiting_for_setup
           .reorder(id: :asc)
  end

  # Called when a check says Play is ready: publishes the waiting releases
  # one minute apart so they don't open concurrent edits on the same app.
  def resume_waiting_play_publishes!
    waiting_play_releases.each_with_index do |release, index|
      AnthropicPlayPublishJob.set(wait: index.minutes).perform_later(release.id)
    end
  end

  # Task 20b — Play-Console-style setup checklist shown on the app's own
  # page (see AppsController#show / apps/_setup_checklist). Deliberately
  # state-driven, not a one-shot "just created" flag: each step reflects
  # what is actually true in the database right now, so the checklist is
  # correct however the app got into that state (re-visits, another
  # collaborator finishing a later step, a step undone) instead of only
  # firing once off a `?created=1`-style redirect param. Ordered hash so
  # callers can rely on iteration order for "which step is next."
  #
  # Anthropic: `first_upload` becoming true means the app is ALREADY live
  # for internal distribution (that's what an upload does, regardless of
  # Play). `package_id` and `published` are Google Play publishing only —
  # optional, admin-approval-gated, and irrelevant to teams that only want
  # internal distribution. The view renders this distinction explicitly
  # rather than presenting all four as one undifferentiated "finish line."
  def setup_checklist_steps
    {
      name: name.present?,
      package_id: play_package_name.present?,
      first_upload: total_releases.positive?,
      published: play_releases_published?
    }
  end

  def setup_checklist_complete?
    setup_checklist_steps.values.all?
  end

  # Task 22: the channel the "Upload your first build" step should send the
  # user to. An .aab (the only thing Play accepts) can only go to an Android
  # channel, so prefer that; otherwise fall back to any channel; nil when the
  # app has no channel yet (then the UI has to lead the user to create a
  # scheme/channel first — there is no upload page without one).
  def first_upload_channel
    scoped = Channel.where(scheme_id: schemes.select(:id)).order(:id)
    scoped.find_by(device_type: :android) || scoped.first
  end

  # Whether Google has actually published a release of this app (distinct
  # from play_approval_status, which only tracks admin sign-off, and from
  # play_setup_status, which tracks whether Play Console itself is ready).
  def play_releases_published?
    Release.where(channel_id: channel_ids).play_publish_published.exists?
  end

  def archive
    update(archived: true)
  end

  def unarchive
    update(archived: false)
  end

  private

  def normalize_play_package_name
    self.play_package_name = play_package_name.to_s.strip.presence
  end

  def play_package_name_format_valid
    return if play_package_name.blank? || play_package_name.match?(PLAY_PACKAGE_NAME_FORMAT)

    errors.add(:play_package_name, I18n.t('apps.messages.errors.invalid_play_package_name'))
  end

  def schedule_play_preflight
    AnthropicPlayPreflightJob.perform_later(id)
  end

  def recently_release_app_id
    id
  end
end
