# frozen_string_literal: true

# Singular resource (config/routes.rb: `resource :play_credential`) — at
# most one PlayCredential (task #7, org-wide singleton). This is the
# Google Cloud service-account key used to *call* the Play Developer API;
# see Admin::PlayUploadKeysController for the separate key that *signs*
# the bundle. Same shape as that controller/AndroidSigningKeysController,
# minus the keytool verify! step — there's nothing to locally verify about
# a service-account JSON beyond "does it parse and have a client_email"
# (PlayCredential#parse_service_account_json handles that at the model
# level on save); whether it actually has API access can only be
# confirmed by a real call, which is exactly what the first publish
# attempt will do.
class Admin::PlayCredentialsController < ApplicationController
  before_action :set_play_credential, only: %i[ show destroy ]

  # GET /admin/play_credential
  def show
  end

  # GET /admin/play_credential/new
  def new
    @play_credential = PlayCredential.new
    authorize @play_credential

    redirect_to admin_play_credential_path, notice: t('.already_configured') if PlayCredential.current
  end

  # POST /admin/play_credential
  def create
    service_account_json = play_credential_params.delete(:service_account_json)
    @play_credential = PlayCredential.new(play_credential_params)
    authorize @play_credential

    @play_credential.service_account_json = service_account_json.respond_to?(:read) ? service_account_json.read : service_account_json

    if @play_credential.save
      redirect_to admin_play_credential_path, notice: t('.successful')
    else
      render :new, status: :unprocessable_entity
    end
  end

  # DELETE /admin/play_credential
  def destroy
    @play_credential.destroy
    notice = t('activerecord.success.destroy', key: t('admin.play_credentials.title'))
    redirect_to new_admin_play_credential_path, status: :see_other, notice: notice
  end

  private

  def set_play_credential
    @play_credential = PlayCredential.current
    redirect_to new_admin_play_credential_path and return unless @play_credential

    authorize @play_credential
  end

  def play_credential_params
    params.require(:play_credential).permit(:service_account_json)
  end
end
