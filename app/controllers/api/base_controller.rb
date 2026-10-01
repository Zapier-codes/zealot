# frozen_string_literal: true

class Api::BaseController < ActionController::API
  include ActionView::Helpers::TranslationHelper
  include Pundit::Authorization
  include ExceptionHandler
  include UserRole
  include Customize
  # Task 37b-iii-s7c-5: sets `Current.tenant` (before the token check in each subclass) so the
  # policies and the scoped lookups below know which host the request came in on.
  include TenantScoped
  # Task 34a-2: helpers for the per-app token path (Authorization: Bearer zpa_...). Opt-in only: no
  # action uses it until its controller declares `before_action :validate_app_token`.
  include Api::AppTokenAuth

  respond_to :json

  around_action :switch_locale
  before_action :set_cache_headers

  rescue_from TypeError, with: :render_unmatched_bundle_id_serror
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found_entity_response
  rescue_from ActiveRecord::RecordInvalid, with: :record_invalid
  rescue_from ActionCable::Connection::Authorization::UnauthorizedError,
              with: :render_unauthorized_user_key
  rescue_from ActiveRecord::RecordNotSaved, ArgumentError, NoMethodError,
              PG::Error, with: :render_internal_server_error
  rescue_from ActionController::ParameterMissing, CarrierWave::InvalidParameter,
              AppInfo::UnknownFormatError, with: :render_missing_params_error
  rescue_from ActionController::UnknownFormat, with: :not_acceptable
  rescue_from ActionController::InvalidAuthenticityToken, with: :unprocessable_entity
  rescue_from Zealot::Error::RecordExisted, with: :render_record_existed_error

  def validate_user_token
    @current_user = User.find_by(token: params[:token])
    raise ActionCable::Connection::Authorization::UnauthorizedError, t('api.unauthorized_token') unless @current_user
  end

  def validate_channel_key
    @channel = Channel.find_by(key: params[:channel_key])
    raise ActionCable::Connection::Authorization::UnauthorizedError, t('api.unauthorized_channel_key') unless @channel
  end

  def record_invalid(e)
    respond_with_error(
      :unprocessable_entity, e,
      error: t('api.unprocessable_entity'),
      entry: e.record.errors
    )
  end

  def forbidden(e)
    policy_name = e.policy.class.to_s.underscore
    respond_with_error(
      :forbidden, e,
      error: t("#{policy_name}.#{e.query}", scope: "pundit", default: :default)
    )
  end

  def not_acceptable(e)
    respond_with_error(:not_acceptable, e)
  end

  def unprocessable_entity(e)
    respond_with_error(:unprocessable_entity, e)
  end

  def render_not_found_entity_response(e)
    respond_with_error(:not_found, e)
  end

  def render_missing_params_error(e)
    respond_with_error(:unprocessable_entity, e)
  end

  def render_unmatched_bundle_id_serror(e)
    respond_with_error(:unauthorized, e)
  end

  def render_unauthorized_user_key(e)
    respond_with_error(:unprocessable_entity, e)
  end

  def render_internal_server_error(e)
    respond_with_error(:internal_server_error, e)
  end

  def render_record_existed_error(e)
    respond_with_error(:conflict, e)
  end

  # workaround for pundit
  def current_user
    @current_user
  end

  def raise_not_found
    exception = Zealot::Error::API::NotFound.new
    respond_with_error(:not_found, exception)
  end

  private

  # Task 37b-iii-s7c-5: the choke point for `/api` lookups by id (cross-cutting rules 2 and 4).
  # Default host: the same unscoped relations as before (no extra subquery). A tenant's host:
  # only that tenant's apps, and the schemes and channels beneath them, so another tenant's id
  # is a plain 404 (`RecordNotFound`) and never a 403 that would confirm it exists.
  def scoped_apps
    policy_scope(App)
  end

  def scoped_schemes
    default_host? ? Scheme.all : Scheme.where(app_id: scoped_apps.select(:id))
  end

  def scoped_channels
    default_host? ? Channel.all : Channel.where(scheme_id: scoped_schemes.select(:id))
  end

  # overwrite
  def respond_with_error(code, e, **body)
    logger_error e
    body[:error] ||= e.message
    if Rails.env.development?
      body[:debug] = { class: e.class }
      body[:debug][:params] = params
      body[:debug][:backtrace] = e.backtrace if e.backtrace.present?
    end

    render json: body, status: code
  end

  def set_cache_headers
    response.headers['Cache-Control'] = 'no-cache, no-store, max-age=0, must-revalidate'
  end

  def logger_error(e)
    return unless Rails.env.development?

    logger.error e.full_message
  end
end
