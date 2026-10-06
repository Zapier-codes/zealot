# frozen_string_literal: true

class Api::Apps::UploadController < Api::BaseController
  include AppArchived

  # Task 34a-5 (Storeapp leaf `f.xiv`): this endpoint takes EITHER credential, never both, never a
  # fallback from one to the other. With an `Authorization: Bearer zpa_...` header the per-app token
  # path runs (Api::AppTokenAuth: header only, `?token=` ignored, the token's creator is the acting
  # user) and the upload is confined to the token's own app; a presented-but-bad `zpa_` header is a
  # 401 and the user token is NOT tried. Without such a header the user-token path is exactly as it
  # was. Order matters: authenticate, then confine the token to its app, and only then parse the file and
  # look the channel up (so another app's archived state is never revealed to a token that is not for it).
  before_action :validate_app_token, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_presented?
  before_action :require_channel_app_token, if: :app_token_presented?
  before_action :set_parser
  before_action :refuse_android_multipart, if: -> { ReleaseUploadSession.direct_upload_required? }
  before_action :set_channel

  # Upload an App
  #
  # POST /api/apps/upload
  #
  # @param token         [String]   required  user token (not read when an `Authorization: Bearer zpa_...`
  #                                              app token header is sent instead; see Api::AppTokenAuth)
  # @param file          [String]   required  file of app
  # @param channel_key   [String]   optional  channel key of app (REQUIRED with an app token: a token
  #                                              uploads into its own app's channel, never creates an app)
  # @param hold          [Boolean]  optional  true: create the release `held`, kept out of the catalog
  #                                              index until it is released (Task 27f-a/b, 34a-5)
  # @param name          [String]   optional  name of app
  # @param password      [String]   optional  password to download app
  # @param release_type  [String]   optional  release type(debug, beta, adhoc, release, enterprise etc)
  # @param source        [String]   optional  upload source(api, cli, jenkins, gitlab-ci etc)
  # @param changelog     [String]   optional  changelog
  # @param branch        [String]   optional  git branch
  # @param git_commit    [String]   optional  git commit
  # @param ci_url        [String]   optional  ci url
  # @return              [String]   json formatted app info
  def create
    create_or_update_release
    perform_teardown_job
    perform_app_web_hook_job

    render json: @release,
           serializer: Api::UploadAppSerializer,
           status: :created
  end

  private

  def create_or_update_release
    ActiveRecord::Base.transaction do
      new_record? ? create_new_app_build : create_build_from_exist_app
    end
  end

  # 创建 App 并创建新版本
  def create_new_app_build
    create_release with_channel and_scheme and_app
  end

  # 使用现有 App 创建新版本
  def create_build_from_exist_app
    # Authorize early for efficiency
    release = @channel.releases.build
    authorize release

    if @channel.bundle_id != '*' && @app_parser &&
       (@channel.device_type == 'ios' || @channel.device_type == 'android')
      message = t('releases.messages.errors.bundle_id_not_matched', got: @app_parser.bundle_id,
        expect: @channel.bundle_id)
      raise TypeError, message unless @channel.bundle_id_matched? @app_parser.bundle_id
    end

    create_release with_updated_channel
  end

  def new_record?
    @channel.blank?
  end

  def perform_app_web_hook_job
    @channel.perform_web_hook('upload_events', current_user.id)
  end

  def perform_teardown_job
    @release.perform_teardown_job(current_user.id)
  end

  ###########################
  # new build methods
  ###########################
  def with_updated_channel
    @channel unless channel_params.present?

    channel = Channel.find_by(key: params[:channel_key])
    channel.update!(channel_params)
    @channel = channel
  end

  def create_release(channel)
    @release = channel.releases.upload_file(release_params, parser: @app_parser, source: 'api')
    authorize @release
    @release.status = 'held' if hold_requested?

    @release.save!
  end

  # Task 34a-5: `hold=true` (also 1/t/yes, as Rails casts a boolean) creates the release `held`
  # (27f-a), so it stays out of the signed index until it is released through the same transition
  # table as the console (`Release::STATUS_TRANSITIONS`). Anything else, or no param, leaves the
  # release `available` exactly as before.
  def hold_requested?
    ActiveModel::Type::Boolean.new.cast(params[:hold]) == true
  end

  # An app token is for ONE existing app. No channel found (a first upload, which would create an app
  # and a scheme) is refused the same way as another app's channel: 403, never a new app. Only runs
  # when an app token was presented (see the before_action above).
  def require_channel_app_token
    require_app_token_for!(Channel.find_by(key: params[:channel_key])&.app)
  end

  def with_channel(scheme)
    @channel = scheme.channels.find_or_create_by(channel_params) do |channel|
      channel.name = @app_parser.platform
      channel.device_type = @app_parser.platform
    end
    authorize @channel
  end

  def and_scheme(app)
    name = parse_scheme_name
    scheme = app.schemes.find_or_create_by(name: name)
    authorize scheme
  end

  # Task 23: this used to be `App.find_or_create_by(name)` followed by
  # `create_owner(current_user)` — so uploading without a channel_key and
  # with the name of somebody else's app attached the upload to *their* app
  # and made the uploader a second owner of it. An existing app is now only
  # reused if the caller may already update it (admin / owner / manage
  # collaborator); otherwise 403. Only a genuinely new app gets an owner, and
  # that owner is the uploader.
  def and_app
    permitted = params.permit :name
    permitted[:name] ||= @app_parser.name

    if (app = App.find_by(permitted))
      authorize app, :update?
    else
      app = App.create!(permitted)
      app.create_owner(current_user)
      authorize app, :create?
    end
    app
  end

  def parse_scheme_name
    default_name = t('api.apps.upload.create.adhoc')
    return default_name unless @app_parser.platform == AppInfo::Platform::IOS

    t("api.apps.upload.create.#{@app_parser.release_type.downcase}", default: default_name)
  end

  def release_params
    params.permit(
      :file, :release_type, :source, :branch, :git_commit,
      :ci_url, :changelog, :devices, :custom_fields
    )
  end

  def channel_params
    @channel_params ||= -> {
      obj = {}
      append_present_value_from_params(obj, :slug)
      append_present_value_from_params(obj, :password)
      append_present_value_from_params(obj, :git_url)
      append_present_value_from_params(obj, :download_filename_type)
      obj
    }.call
  end

  # Task 40r: with REQUIRE_DIRECT_UPLOAD on, an Android file may not arrive as a multipart body (it would land on
  # Render's disk): the answer says where to go instead. Only the transport is refused; the same file goes
  # through `POST /api/apps/upload_sessions` (R2 staging, then CI signs it and injects the SDK as always).
  # Other formats keep this door. Runs after authentication and the per-app-token confinement, so only a caller
  # who could have uploaded learns the rule, and before the channel lookup, so nothing is created.
  def refuse_android_multipart
    return unless ReleaseUploadSession.android_file?(params[:file]) || @app_parser&.platform.to_s == 'android'

    render json: { error: t('api.direct_upload_required') }, status: :upgrade_required
  end

  def set_parser
    @app_parser = AppInfo.parse(params[:file].path)
  rescue AppInfo::UnknownFormatError
    @app_parser = nil
  end

  def set_channel
    @channel = Channel.find_by(key: params[:channel_key])
    # Task 23: a first upload has no channel yet (see #new_record?); this line
    # used to dereference nil there and the request ended in a 500.
    raise_if_app_archived!(@channel.app) if @channel
  end

  def append_present_value_from_params(data, key)
    return unless value = params[key]

    if key == :password && value.blank?
      data[key] = nil
      return
    end

    data[key] = value if value.present?
  end
end
