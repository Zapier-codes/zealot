# frozen_string_literal: true

# Task 40h-b: opens a direct-to-storage upload. Both doors (the console and the API) call this after their own
# authentication and authorization; nothing here decides who may upload. It creates the `release_uploads` row
# in `awaiting_bytes` and returns a presigned PUT for the staging bucket, so the file never reaches Render.
#
#   ReleaseUploadSession.enabled?   # false unless RELEASE_UPLOAD_SESSIONS_ENABLED is exactly "true" AND the
#                                   # four R2_STAGING_* variables are set; the doors answer 404 until then
#   session = ReleaseUploadSession.new(channel: channel, user: user, params: params).call
#   # Task 40r: `channel: nil` opens the FIRST upload of an app (API door only). The row is marked
#   # `form_options['new_app']`; the app, scheme and channel are created at stage 1 (ReleaseUploadAppResolver).
#   session.upload      # the ReleaseUpload row
#   session.presigned   # ReleaseUploadStaging::Presigned (url, method, headers, expires_at)
#
# `params` is the already-permitted request data: `filename` and `size` are required, `content_type` is
# optional (when present it is signed into the URL and the client must send the same header), and the keys in
# FORM_OPTION_KEYS are copied to `form_options` untouched. Nothing in `form_options` is trusted or acted on
# until the release exists (40i-b re-runs every check then).
#
# If the presign fails after the row was written, the row is marked `failed` with the reason (so no row is
# left `awaiting_bytes` with no URL anywhere) and the error is raised to the door as a 503.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class ReleaseUploadSession
  FORM_OPTION_KEYS = %w[
    hold play_store_target changelog branch git_commit ci_url release_type source custom_fields devices
  ].freeze

  # Task 40r: what the owner may choose for a brand-new app and channel (the multipart door's `name`, `slug`,
  # `git_url` and `download_filename_type`). The channel's download `password` is deliberately NOT here: it
  # would sit in plain text in `release_uploads.form_options`; set it in the console after the first release.
  NEW_APP_KEYS = %w[name slug git_url download_filename_type].freeze

  # Task 40r: the files that must go through a session once REQUIRE_DIRECT_UPLOAD is on. Stage 1 only reads
  # these two kinds (`ReleaseUploadIntake::KINDS`); every other format keeps the multipart door.
  ANDROID_EXTENSIONS = %w[.apk .aab].freeze

  # `payload` is what both doors return to the client. It carries the presigned URL (a bearer token for one
  # PUT, good until `expires_at`) and the headers the client must send with it; it never carries the staging
  # key, which only Zealot and CI need.
  Result = Struct.new(:upload, :presigned, keyword_init: true) do
    def payload
      { id: upload.id, state: upload.state, upload_url: presigned.url, method: presigned.method,
        headers: presigned.headers, expires_at: presigned.expires_at.iso8601, size: upload.declared_size }
    end
  end

  def self.enabled?
    ENV['RELEASE_UPLOAD_SESSIONS_ENABLED'] == 'true' && ReleaseUploadStaging.configured?
  end

  # Task 40r: true when Android uploads may no longer arrive as multipart bodies on Render. Needs the sessions
  # to be usable (`enabled?`) so turning it on can never leave an Android upload with no door at all.
  def self.direct_upload_required?
    ENV['REQUIRE_DIRECT_UPLOAD'] == 'true' && enabled?
  end

  # @param file [#original_filename, nil] an uploaded multipart file
  def self.android_file?(file)
    name = file.respond_to?(:original_filename) ? file.original_filename.to_s : ''
    ANDROID_EXTENSIONS.include?(File.extname(name).downcase)
  end

  def initialize(channel:, user:, params:, staging: nil)
    @channel = channel
    @user = user
    @params = params
    @staging = staging
  end

  # @return [Result]
  # @raise [ActiveRecord::RecordInvalid] a missing or out-of-range file name or size
  # @raise [ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError] the presign failed
  def call
    upload = ReleaseUpload.create!(
      channel: @channel, user: @user, filename: @params[:filename], content_type: @params[:content_type].presence,
      declared_size: integer_size, form_options: form_options
    )
    presigned = presign(upload)
    Result.new(upload: upload, presigned: presigned)
  end

  private

  # `Integer()` would raise ArgumentError for "abc"; a size that is not a whole number is just invalid, so it
  # becomes nil and the model's numericality validation reports it like any other bad value.
  def integer_size
    Integer(@params[:size].to_s, 10)
  rescue ArgumentError
    nil
  end

  def form_options
    options = @params.to_h.stringify_keys.slice(*FORM_OPTION_KEYS)
    return options if @channel

    options.merge(@params.to_h.stringify_keys.slice(*NEW_APP_KEYS).compact_blank).merge('new_app' => true)
  end

  def presign(upload)
    (@staging || ReleaseUploadStaging.new).presign_put(upload)
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    ReleaseUpload.where(id: upload.id, state: 'awaiting_bytes')
                 .update_all(state: 'failed', error: e.message.to_s.truncate(1000), updated_at: Time.current)
    raise
  end
end
