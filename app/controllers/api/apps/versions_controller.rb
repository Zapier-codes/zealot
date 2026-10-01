# frozen_string_literal: true

class Api::Apps::VersionsController < Api::BaseController
  # Task 34a-2: the one endpoint that proves the per-app token path (read-only). Without an
  # `Authorization: Bearer zpa_...` header nothing changes: the channel key alone still answers. WITH
  # one, the token must be valid (401 otherwise, never a silent fall back to the channel key) and the
  # channel must belong to the token's app (403 otherwise).
  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_channel_key
  before_action :require_channel_app_token, if: :app_token_presented?

  # GET /api/apps/versions
  def index
    render json: @channel,
           serializer: Api::AppVersionsSerializer,
           page: params.fetch(:page, 1).to_i,
           per_page: params.fetch(:per_page, 10).to_i
  end

  private

  def require_channel_app_token
    require_app_token_for!(@channel.app)
  end
end
