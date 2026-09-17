# frozen_string_literal: true

# Singular resource (config/routes.rb: `resource :android_signing_key`) —
# there is at most one AndroidSigningKey (task #5, org-wide singleton).
# Mirrors Admin::AppleKeysController's shape where it still applies (file
# upload -> model, checksum-deduped, destroy-then-recreate to rotate)
# rather than the App-nested pattern originally planned for this task,
# since the operator moved the key from per-App to org-wide this session.
class Admin::AndroidSigningKeysController < ApplicationController
  before_action :set_android_signing_key, only: %i[ show destroy ]

  # GET /admin/android_signing_key
  def show
  end

  # GET /admin/android_signing_key/new
  def new
    @android_signing_key = AndroidSigningKey.new
    authorize @android_signing_key

    redirect_to admin_android_signing_key_path, notice: t('.already_configured') if AndroidSigningKey.current
  end

  # POST /admin/android_signing_key
  def create
    keystore = android_signing_key_params.delete(:keystore)
    @android_signing_key = AndroidSigningKey.new(android_signing_key_params)
    authorize @android_signing_key

    @android_signing_key.keystore = keystore&.read
    @android_signing_key.filename = keystore&.original_filename

    unless @android_signing_key.valid?
      return render :new, status: :unprocessable_entity
    end

    # Best-effort: confirm the alias/passwords actually open this keystore
    # before it's trusted for real builds. Requires `keytool` (same JDK
    # bundletool needs) on whatever host this runs on — if that's missing
    # here, don't silently accept an unverified keystore; surface it.
    begin
      @android_signing_key.verify!
    rescue Anthropic::ApkSigningService::KeytoolNotFoundError => e
      @android_signing_key.errors.add(:base, :keytool_unavailable, message: e.message)
      return render :new, status: :unprocessable_entity
    rescue Anthropic::ApkSigningService::InvalidKeystoreError => e
      @android_signing_key.errors.add(:base, :verification_failed, message: e.message)
      return render :new, status: :unprocessable_entity
    end

    if @android_signing_key.save
      redirect_to admin_android_signing_key_path, notice: t('.successful')
    else
      render :new, status: :unprocessable_entity
    end
  end

  # DELETE /admin/android_signing_key
  def destroy
    @android_signing_key.destroy
    notice = t('activerecord.success.destroy', key: t('admin.android_signing_keys.title'))
    redirect_to new_admin_android_signing_key_path, status: :see_other, notice: notice
  end

  private

  def set_android_signing_key
    @android_signing_key = AndroidSigningKey.current
    redirect_to new_admin_android_signing_key_path and return unless @android_signing_key

    authorize @android_signing_key
  end

  def android_signing_key_params
    params.require(:android_signing_key).permit(:key_alias, :keystore_password, :key_password, :keystore)
  end
end
