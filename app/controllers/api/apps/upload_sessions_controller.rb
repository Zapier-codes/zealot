# frozen_string_literal: true

# Task 40h-b: the API door of the direct-to-storage upload (decided Task 40 flow), for a developer's own CI. It
# takes the same two credentials as `Api::Apps::UploadController`, never both and never a fallback from one to
# the other: a per-app token (`Authorization: Bearer zpa_...`, confined to its own app) or the user token. The
# multipart `POST /api/apps/upload` stays as it is until 40k.
#
#   POST /api/apps/upload_sessions                -> 201 { id, upload_url, method, headers, expires_at, size }
#   POST /api/apps/upload_sessions/:id/finalize   -> 200 { id, state } | 4xx/503 { error }
#
# `channel_key` is required: a session is for an EXISTING channel, so it never creates an app, a scheme or a
# channel (a first upload still goes through the multipart endpoint). The caller must pass
# `ReleasePolicy#create?` for the channel's app, as for the multipart door. Nothing here creates a `Release`
# (that is CI's callback, 40i-b). Finalize only works for the user who opened the upload, and, for an app token,
# only for its own app. The door answers 404 until `ReleaseUploadSession.enabled?`.
#
# @param channel_key  [String]  required  (create)
# @param filename     [String]  required  (create)
# @param size         [Integer] required  bytes, 1 to 2 GiB - 1 (create)
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
  before_action :set_upload, only: :finalize
  before_action :confine_app_token, if: :app_token_presented?
  before_action :authorize_upload

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
    render json: { id: @upload.id, state: @upload.reload.state, error: result.error }.compact, status: result.http
  end

  private

  def require_sessions_enabled
    head :not_found unless ReleaseUploadSession.enabled?
  end

  # A missing or foreign channel is a plain 404 (`scoped_channels` also hides another tenant's channels).
  def set_channel
    @channel = scoped_channels.find_by!(key: params[:channel_key])
  end

  def set_upload
    @upload = ReleaseUpload.where(channel_id: scoped_channels.select(:id), user_id: current_user.id)
                           .find(params[:id])
    @channel = @upload.channel
  end

  def confine_app_token
    require_app_token_for!(@channel.app)
  end

  def authorize_upload
    raise_if_app_archived!(@channel.app)
    authorize Release.new(channel: @channel), :create?
  end

  # `source` is never read from the client: the door sets it.
  def session_params
    params.permit(:filename, :size, :content_type, *(ReleaseUploadSession::FORM_OPTION_KEYS - %w[source]))
  end
end
