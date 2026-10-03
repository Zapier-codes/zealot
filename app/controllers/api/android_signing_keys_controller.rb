# frozen_string_literal: true

# Task 34d-1 (D-Store leaf 35, `7.a.xi.zi`): the org-wide Android signing key over the API, so it can be put in
# place by a script instead of only through the browser form (Admin::AndroidSigningKeysController, task #5).
# Same singleton shape as the admin resource and as Api::PlayCredentialsController: AndroidSigningKey
# itself still enforces "only one record" and the presence rules; this controller adds the token door,
# the admin-only policy, a size cap and the same keystore check the form runs.
#
#   GET    /api/android_signing_key              metadata of the key, 404 when none is configured
#   POST   /api/android_signing_key              multipart/form-data: keystore (file), key_alias,
#                                                keystore_password, key_password
#   DELETE /api/android_signing_key?checksum=... remove the key; the checksum must be the current key's
#
# Credentials: the user token from `Authorization: Bearer <token>` ONLY (Api::UserTokenHeaderAuth), never
# `?token=`, and never a per-app token. Who may call: platform admins only (AndroidSigningKeyPolicy). The
# policy is asked BEFORE the key is looked up, so a caller who is not an admin gets the same 403 whether or
# not a key exists and learns nothing about it.
#
# Never answers with the keystore or either password: see Api::AndroidSigningKeySerializer. The passwords
# are request-body fields (multipart), never URL parameters, and `keystore`, `passw*` are in
# `filter_parameters`, so they are not written to the log.
#
# Rotation is delete-then-create, as in the console. Removing the key is the one dangerous action here
# (every later release is unsigned until a key is added back, and a different keystore changes the
# signature of every future release), so DELETE asks the caller to name the checksum it means to remove:
# a stale script or a mistyped call cannot remove a key it did not read first.
class Api::AndroidSigningKeysController < Api::BaseController
  include Api::UserTokenHeaderAuth

  # A real keystore is a few kilobytes. The cap stops an arbitrary upload from being read into memory and
  # written, encrypted, to the database. 1 MB is a choice, not a standard.
  MAX_KEYSTORE_BYTES = 1.megabyte

  before_action :validate_user_token_header
  before_action :authorize_signing_key
  before_action :set_android_signing_key, only: %i[ show destroy ]

  # GET /api/android_signing_key
  def show
    render json: @android_signing_key, serializer: Api::AndroidSigningKeySerializer
  end

  # POST /api/android_signing_key
  def create
    return render json: { error: t('api.signing_key_already_configured') }, status: :conflict if AndroidSigningKey.current

    upload = params[:keystore]
    unless upload.respond_to?(:read) && upload.respond_to?(:original_filename)
      return render json: { error: t('api.signing_key_keystore_missing') }, status: :unprocessable_entity
    end

    bytes = upload.read(MAX_KEYSTORE_BYTES + 1)
    if bytes.nil? || bytes.empty?
      return render json: { error: t('api.signing_key_keystore_missing') }, status: :unprocessable_entity
    end
    if bytes.bytesize > MAX_KEYSTORE_BYTES
      return render json: { error: t('api.signing_key_keystore_too_large', max: MAX_KEYSTORE_BYTES) },
                    status: 413
    end

    @android_signing_key = AndroidSigningKey.new(signing_key_params)
    @android_signing_key.keystore = bytes
    @android_signing_key.filename = File.basename(upload.original_filename.to_s)
    return render_unprocessable unless @android_signing_key.valid?

    # Confirm the alias and passwords really open this keystore before it is trusted for real builds, the
    # same check the form runs. A missing `keytool` is the host's problem, not the caller's: say so (503)
    # rather than accept a keystore nobody has checked.
    begin
      @android_signing_key.verify!
    rescue Anthropic::ApkSigningService::KeytoolNotFoundError => e
      return render json: { error: t('api.signing_key_keytool_unavailable'), detail: e.message },
                    status: :service_unavailable
    rescue Anthropic::ApkSigningService::InvalidKeystoreError => e
      @android_signing_key.errors.add(:base, :verification_failed, message: e.message)
      return render_unprocessable
    end

    if @android_signing_key.save
      audit('created')
      render json: @android_signing_key, serializer: Api::AndroidSigningKeySerializer, status: :created
    else
      render_unprocessable
    end
  end

  # DELETE /api/android_signing_key?checksum=<current checksum>
  def destroy
    unless ActiveSupport::SecurityUtils.secure_compare(params[:checksum].to_s, @android_signing_key.checksum.to_s)
      return render json: { error: t('api.signing_key_checksum_mismatch') }, status: :conflict
    end

    @android_signing_key.destroy!
    audit('removed')
    render json: { message: 'OK' }, status: :accepted
  end

  private

  # Asked first, on the class, so the answer does not depend on whether a key exists.
  def authorize_signing_key
    authorize AndroidSigningKey, :"#{action_name}?"
  end

  def set_android_signing_key
    @android_signing_key = AndroidSigningKey.current
    raise ActiveRecord::RecordNotFound if @android_signing_key.nil?
  end

  def signing_key_params
    params.permit(:key_alias, :keystore_password, :key_password)
  end

  def render_unprocessable
    render json: { error: t('api.unprocessable_entity'), entry: @android_signing_key.errors },
           status: :unprocessable_entity
  end

  # One log line per change, with who and which key (by its public checksum), never a secret. A stand-in
  # until the audit log of Task 34c exists.
  def audit(what)
    Rails.logger.info("[android_signing_key] #{what} by user=#{current_user.id} checksum=#{@android_signing_key.checksum}")
  end
end
