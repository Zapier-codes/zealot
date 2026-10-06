# frozen_string_literal: true

# Task 40h-b: the API door of the direct-to-storage upload (decided Task 40 flow), for a developer's own CI. It
# takes the same two credentials as `Api::Apps::UploadController`, never both and never a fallback from one to
# the other: a per-app token (`Authorization: Bearer zpa_...`, confined to its own app) or the user token. The
# multipart `POST /api/apps/upload` stays as it is until 40k.
#
#   POST /api/apps/upload_sessions                -> 201 { id, upload_url, method, headers, expires_at, size }
#   POST /api/apps/upload_sessions/:id/finalize   -> 200 { id, state } | 4xx/503 { error }
#   GET  /api/apps/upload_sessions/:id            -> 200 { id, state, error?, release_id?, app_id?, ... } (Task 40h-c-2)
#   POST /api/apps/upload_sessions/:id/parts      -> 200 { parts: [{ part_number, url, method, headers, size, ... }] }
#   GET  /api/apps/upload_sessions/:id/parts      -> 200 { uploaded: [...], missing: [...] }
#
# Task 40s-c: a file of at least RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB (default 100) is opened in parts when
# RELEASE_UPLOAD_MULTIPART_ENABLED is on. `create` then answers `{ id, state, multipart: true, part_size,
# part_count, expires_at, size }` and no `upload_url`: the caller cuts the file into `part_size` pieces (the last
# one is what is left), asks `POST .../parts` with `parts=[1,2,3,4]` (at most 10 numbers) for one presigned PUT
# per part, sends each part to R2 (a failed part is signed again and resent), asks `GET .../parts` after a
# dropped connection to learn which parts R2 holds, and calls finalize when `missing` is empty. Finalize answers
# 422 `{ code: "parts_incomplete", missing: [...] }` when parts are missing; the upload stays open. Same
# credentials and ownership rule as finalize and show. A file under the threshold keeps the single `upload_url`.
#
# Task 40h-c-2: `show` is how a CI that opened a session learns the outcome. Finalize answers as soon as the
# bytes are in staging; CI then reads the file and builds (minutes), and the release exists only from the first
# callback. The caller polls `show` until `state` is `done` (the release is finished: `release_id`, `app_id`,
# `release_version`, `build_version`, `release_url` and the release `status` are present, `held` when the upload
# asked for `hold`) or `failed` (`error` says why). Same credentials and same ownership rule as finalize: only
# the user who opened the upload sees it, and a per-app token only its own app. Read-only; it changes nothing.
#
# `channel_key` names an EXISTING channel. Task 40r: it may be left out for the FIRST upload of an app, which
# is how a new app now reaches Zealot without a multipart body. Nothing is created here: the row is marked
# `new_app` and the app, scheme and channel are made at stage 1 (`ReleaseUploadAppResolver`), once CI has read
# the package name. Optional `name`, `slug`, `git_url` and `download_filename_type` shape the new app and
# channel (the channel `password` is not accepted). The caller must pass `AppPolicy#create?` (the multipart
# door's rule for a new app), a per-app token is refused (it is for one existing app), and only the default
# host takes it (a tenant host's first upload is not available through a session). With a channel_key the
# caller must pass `ReleasePolicy#create?` for the channel's app, as for the multipart door. Nothing here
# creates a `Release` (that is CI's callback, 40i-b). Finalize only works for the user who opened the upload, and, for an app token,
# only for its own app. The door answers 404 until `ReleaseUploadSession.enabled?`.
#
# @param channel_key  [String]  optional  (create) omit for the first upload of an app (Task 40r)
# @param filename     [String]  required  (create)
# @param size         [Integer] required  bytes, 1 to 2 GiB - 1 (create)
# @param name, slug, git_url, download_filename_type
#                     optional  only without a channel_key: the new app's name and its channel's options
# @param content_type [String]  optional  signed into the URL when sent; the PUT must then carry the same header
# @param hold, play_store_target, changelog, branch, git_commit, ci_url, release_type, custom_fields, devices
#                     optional  kept on the upload record, not trusted until the release exists
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class Api::Apps::UploadSessionsController < Api::BaseController
  include AppArchived

  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_presented?
  before_action :require_sessions_enabled
  before_action :set_channel, only: :create
  before_action :set_upload, only: %i[finalize show sign_parts list_parts]
  before_action :confine_app_token, if: :app_token_presented?
  before_action :authorize_upload
  before_action :authorize_new_app, if: :new_app_session?

  def create
    session = ReleaseUploadSession.new(channel: @channel, user: current_user,
                                       params: session_params.merge(source: 'api')).call
    render json: session.payload, status: :created
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    logger.error("[Api::Apps::UploadSessionsController] presign failed: #{e.message}")
    render json: { error: 'Direct upload is unavailable right now.' }, status: :service_unavailable
  end

  def finalize
    result = ReleaseUploadFinalizer.new(@upload).call
    render json: { id: @upload.id, state: @upload.reload.state, error: result.error }.merge(result.details).compact,
           status: result.http
  end

  # Task 40s-c
  def sign_parts
    result = ReleaseUploadPartSigner.new(@upload).sign(ReleaseUploadPartSigner.parse_numbers(params[:parts]))
    render json: result.body, status: result.http
  end

  # Task 40s-c
  def list_parts
    result = ReleaseUploadPartSigner.new(@upload).list
    render json: result.body, status: result.http
  end

  # Task 40h-c-2
  def show
    render json: status_payload(@upload.reload)
  end

  private

  # `compact` drops what is not known yet (no release before stage 1, no error unless failed).
  def status_payload(upload)
    release = upload.release
    {
      id: upload.id, state: upload.state, error: upload.error.presence,
      release_id: release&.id, app_id: release&.app&.id, status: release&.status,
      release_version: release&.release_version, build_version: release&.build_version,
      release_url: release&.release_url
    }.compact
  end

  def require_sessions_enabled
    head :not_found unless ReleaseUploadSession.enabled?
  end

  # A missing or foreign channel is a plain 404 (`scoped_channels` also hides another tenant's channels).
  # Task 40r: no `channel_key` at all is the first upload of an app (`@channel` stays nil); a key that is sent
  # but matches nothing is still a 404, never a silent switch to "new app".
  def set_channel
    return unless params.key?(:channel_key)

    @channel = scoped_channels.find_by!(key: params[:channel_key])
  end

  # Task 40r: a channel-less upload belongs to its uploader alone and is only visible on the default host.
  def set_upload
    owned = ReleaseUpload.where(user_id: current_user.id)
    scope = owned.where(channel_id: scoped_channels.select(:id))
    scope = scope.or(owned.where(channel_id: nil)) if default_host?
    @upload = scope.find(params[:id])
    @channel = @upload.channel
  end

  def confine_app_token
    require_app_token_for!(@channel&.app)
  end

  def authorize_upload
    return if @channel.nil?

    raise_if_app_archived!(@channel.app)
    authorize Release.new(channel: @channel), :create?
  end

  # Task 40r: no channel means the first upload of an app, for create, finalize and show alike (a row that
  # was opened that way keeps `channel_id` nil until stage 1).
  def new_app_session?
    @channel.nil?
  end

  # The rules the multipart door applies to a first upload, asked up front so a caller who could never finish
  # finds out before sending bytes (the same rules run again at stage 1, which is the check that counts).
  def authorize_new_app
    return render(json: { error: t('api.new_app_session_default_host_only') }, status: :forbidden) unless default_host?
    return if AppPolicy.new(current_user, App.new).create?

    render json: { error: t('api.new_app_session_refused') }, status: :forbidden
  end

  # `source` is never read from the client: the door sets it. The new-app keys are only kept without a channel
  # (`ReleaseUploadSession` ignores them otherwise).
  def session_params
    params.permit(:filename, :size, :content_type, *ReleaseUploadSession::NEW_APP_KEYS,
                  *(ReleaseUploadSession::FORM_OPTION_KEYS - %w[source]))
  end
end
