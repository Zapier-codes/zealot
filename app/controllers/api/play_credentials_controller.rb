# frozen_string_literal: true

# Token-authenticated, admin-only mirror of Admin::PlayCredentialsController
# (task #7), added so the org-wide Play service-account credential can be
# provisioned/rotated by script instead of only through the browser admin
# form. Same singleton shape as the admin resource — PlayCredential itself
# still enforces "only one record" and parses client_email/project_id on
# save (see the model) — this controller adds nothing beyond token auth +
# the admin?-only policy (see PlayCredentialPolicy for why that override is
# load-bearing here, unlike in the session-authenticated admin namespace).
#
# Never renders service_account_json back out — see Api::PlayCredentialSerializer.
class Api::PlayCredentialsController < Api::BaseController
  before_action :validate_user_token
  before_action :set_play_credential, only: %i[ show destroy ]

  # GET /api/play_credential
  def show
    render json: @play_credential, serializer: Api::PlayCredentialSerializer
  end

  # POST /api/play_credential
  def create
    @play_credential = PlayCredential.new(play_credential_params)
    authorize @play_credential

    if @play_credential.save
      render json: @play_credential, serializer: Api::PlayCredentialSerializer, status: :created
    else
      render json: { error: t('api.unprocessable_entity'), entry: @play_credential.errors }, status: :unprocessable_entity
    end
  end

  # DELETE /api/play_credential
  def destroy
    @play_credential.destroy
    render json: { message: 'OK' }, status: :accepted
  end

  private

  def set_play_credential
    @play_credential = PlayCredential.current
    raise ActiveRecord::RecordNotFound if @play_credential.nil?

    authorize @play_credential
  end

  def play_credential_params
    params.permit(:service_account_json)
  end
end
