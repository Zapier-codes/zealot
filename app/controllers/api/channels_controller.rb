# frozen_string_literal: true

class Api::ChannelsController < Api::BaseController
  include AppArchived

  # Task 34a-4 (Storeapp leaf `f.xiv`): `update` is the ONE action here that accepts a per-app token
  # (`Authorization: Bearer zpa_...`, see Api::AppTokenAuth), and with a token only `track` can change.
  # Every other action, and `update` without a zpa_ header, keeps the user-token check it always had.
  before_action :validate_app_token, only: :update, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_update_request?
  before_action :require_channel_app_token, only: :update, if: :app_token_presented?
  before_action :set_scheme, only: %i[index create]
  before_action :set_channel, only: %i[show update destroy]
  before_action :require_valid_track, only: %i[create update]

  # GET /api/schemes/:scheme_id/channels
  def index
    render json: @scheme.channels
  end

  # POST /api/schemes/:scheme_id/channels
  def create
    raise_if_app_archived!(@scheme.app)

    @channel = @scheme.channels.create!(channel_params)
    authorize @channel

    render json: @channel
  end

  # GET /api/channels/:id
  def show
    render json: @channel
  end

  # PUT/PATCH /api/channels/:id
  #
  # Task 34a-4: `track` (internal, closed, open or production) can be set here. WARNING, same as in the
  # console: only `production` channels feed the public catalog index, so moving a channel to any other
  # track takes its releases out of the next published index. An unknown track is a 422.
  def update
    raise_if_app_archived!(@channel.app)

    @channel.update!(channel_params)
    render json: @channel
  end

  # DELETE /api/channels/:id
  def destroy
    raise_if_app_archived!(@channel.app)

    @channel.destroy!
    render json: { mesage: 'OK' }
  end

  protected

  def set_scheme
    @scheme = scoped_schemes.find(params[:scheme_id])
    authorize @scheme
  end

  def set_channel
    @channel = scoped_channels.find(params[:id])
    authorize @channel
  end

  # Task 34a-4: a per-app token may change `track` and nothing else (decision 34-4: the `publish` scope
  # is a track change, not a channel edit). The user-token path also gains `track`.
  def channel_params
    @channel_params ||= if @app_token
      params.permit(:track)
    else
      params.permit(
        :name, :slug, :device_type, :bundle_id, :password, :git_url, :download_filename_type, :track
      )
    end
  end

  def app_token_update_request?
    action_name == 'update' && app_token_presented?
  end

  # Runs before the channel is looked up: a token for another app's channel is a 403, not a 404.
  def require_channel_app_token
    require_app_token_for!(Channel.find_by(id: params[:id])&.app)
  end

  # Assigning an unknown value to a Rails enum raises ArgumentError (a 500 in this base controller), so
  # the value is checked here and answered as a 422 with the allowed list.
  def require_valid_track
    return unless params.key?(:track)
    return if Channel.tracks.key?(params[:track].to_s)

    render json: { error: t('api.channel_track_invalid', tracks: Channel.tracks.keys.to_sentence) },
           status: :unprocessable_entity
  end
end
