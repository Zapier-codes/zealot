# frozen_string_literal: true

# Task 40h-b: the console door of the direct-to-storage upload (decided Task 40 flow). The signed-in owner asks
# for an upload, gets a presigned PUT for the staging bucket, sends the file there, then finalizes. Render never
# sees the bytes. The existing multipart `ReleasesController#create` is untouched and stays until 40k.
#
#   POST /channels/:channel_id/release_uploads                 -> 201 { id, upload_url, method, headers, ... }
#   POST /channels/:channel_id/release_uploads/:id/finalize    -> 200 { id, state } | 4xx/503 { error }
#   POST /channels/:channel_id/release_uploads/:id/parts       -> 200 { parts: [{ part_number, url, ... }] } (40s-c)
#   GET  /channels/:channel_id/release_uploads/:id/parts       -> 200 { uploaded: [...], missing: [...] } (Task 40s-c)
#
# Task 40s-c: a file of at least RELEASE_UPLOAD_MULTIPART_THRESHOLD_MIB is opened in parts when
# RELEASE_UPLOAD_MULTIPART_ENABLED is on: `create` then answers `{ id, state, multipart: true, part_size,
# part_count, expires_at, size }` (no `upload_url`), the client asks `POST .../parts` for up to 10 part URLs at a
# time, PUTs each part to R2, asks `GET .../parts` to resume, and finalizes as before. The page's uploader
# script must know this answer (Task 40s-d) before the flag is turned on for the console.
#
# Both actions are JSON-only and need a real signed-in user (guest mode does not apply: unlike the install page,
# an upload is never public) who may upload to the channel's app (`ReleasePolicy#create?`, the same rule as the
# upload form). Neither creates a `Release`: that happens only when CI calls back with the parsed file (40i-b),
# which is why `spec/requests/manual_upload_only_spec.rb` pins who may create a `release_uploads` row.
#
# The whole door answers 404 until `ReleaseUploadSession.enabled?` (flag on and the staging bucket configured).
# An upload can only be finalized by the user who opened it.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class ReleaseUploadsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :require_sessions_enabled
  before_action :set_channel
  before_action :authorize_upload
  before_action :set_upload, only: %i[finalize sign_parts list_parts]

  def create
    session = ReleaseUploadSession.new(channel: @channel, user: current_user,
                                       params: session_params.merge(source: 'web')).call
    render json: session.payload, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.to_sentence, entry: e.record.errors },
           status: :unprocessable_entity
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    logger.error("[ReleaseUploadsController] presign failed: #{e.message}")
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

  private

  # Only the user who opened the upload, on this channel.
  def set_upload
    @upload = ReleaseUpload.where(channel_id: @channel.id, user_id: current_user.id).find(params[:id])
  end

  def require_sessions_enabled
    head :not_found unless ReleaseUploadSession.enabled?
  end

  def set_channel
    @channel = Channel.friendly.find(params[:channel_id])
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
