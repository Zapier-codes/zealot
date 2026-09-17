# frozen_string_literal: true

# Singular resource (config/routes.rb: `resource :play_upload_key`) — at
# most one PlayUploadKey (task #7, org-wide singleton, deliberately
# separate from AndroidSigningKey — see that model's comments). Mirrors
# Admin::AndroidSigningKeysController's shape exactly; the two controllers
# stay near-identical on purpose since the two keys are managed the same
# way, just kept as separate records/tables.
class Admin::PlayUploadKeysController < ApplicationController
  before_action :set_play_upload_key, only: %i[ show destroy ]

  # GET /admin/play_upload_key
  def show
  end

  # GET /admin/play_upload_key/new
  def new
    @play_upload_key = PlayUploadKey.new
    authorize @play_upload_key

    redirect_to admin_play_upload_key_path, notice: t('.already_configured') if PlayUploadKey.current
  end

  # POST /admin/play_upload_key
  def create
    keystore = play_upload_key_params.delete(:keystore)
    @play_upload_key = PlayUploadKey.new(play_upload_key_params)
    authorize @play_upload_key

    @play_upload_key.keystore = keystore&.read
    @play_upload_key.filename = keystore&.original_filename

    unless @play_upload_key.valid?
      return render :new, status: :unprocessable_entity
    end

    begin
      @play_upload_key.verify!
    rescue Anthropic::ApkSigningService::KeytoolNotFoundError => e
      @play_upload_key.errors.add(:base, :keytool_unavailable, message: e.message)
      return render :new, status: :unprocessable_entity
    rescue Anthropic::ApkSigningService::InvalidKeystoreError => e
      @play_upload_key.errors.add(:base, :verification_failed, message: e.message)
      return render :new, status: :unprocessable_entity
    end

    if @play_upload_key.save
      redirect_to admin_play_upload_key_path, notice: t('.successful')
    else
      render :new, status: :unprocessable_entity
    end
  end

  # DELETE /admin/play_upload_key
  def destroy
    @play_upload_key.destroy
    notice = t('activerecord.success.destroy', key: t('admin.play_upload_keys.title'))
    redirect_to new_admin_play_upload_key_path, status: :see_other, notice: notice
  end

  private

  def set_play_upload_key
    @play_upload_key = PlayUploadKey.current
    redirect_to new_admin_play_upload_key_path and return unless @play_upload_key

    authorize @play_upload_key
  end

  def play_upload_key_params
    params.require(:play_upload_key).permit(:key_alias, :keystore_password, :key_password, :keystore)
  end
end
