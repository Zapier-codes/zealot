# frozen_string_literal: true

module ExceptionHandler
  extend ActiveSupport::Concern

  included do
    rescue_from ActiveRecord::RecordNotFound, ActionController::RoutingError,
                ActionController::MissingFile, Zealot::Error::RecordNotFound,
                with: :not_found
    rescue_from ActionController::InvalidAuthenticityToken, with: :unprocessable_entity
    rescue_from ActionController::UnknownFormat, AppInfo::Error, Errno::ECONNREFUSED,
                with: :not_acceptable
    rescue_from ActionController::ParameterMissing, CarrierWave::InvalidParameter,
                JSON::ParserError, AppInfo::UnknownFormatError, Zealot::Error::AppArchivedDeny,
                with: :bad_request
    rescue_from Faraday::Error, OpenSSL::SSL::SSLError,
                TinyAppstoreConnect::ConnectAPIError, with: :internal_server_error
    rescue_from Pundit::NotAuthorizedError, with: :forbidden
    rescue_from ActiveRecord::ConnectionNotEstablished, with: :internal_server_error
    rescue_from Net::SMTPAuthenticationError, with: :unauthorized
  end

  private

  def unauthorized(e)
    respond_with_error(401, e)
  end

  # Task 37b-iii-s7c-2b (cross-cutting rule 2): on a tenant's host, a denial about a record that
  # belongs to ANOTHER tenant (or to the default catalog) answers 404, the same as a record that does
  # not exist, so the console is no existence oracle across tenants. Every other denial stays 403.
  def forbidden(e)
    return not_found(cross_tenant_not_found(e.record)) if cross_tenant_denial?(e)

    respond_with_error(403, e)
  end

  # True only when all of these hold: the controller knows the request's tenant (`TenantScoped`;
  # `Api::BaseController` does not, until s7c-5), the request is on a tenant's host, the denied
  # record is a SAVED row of a tenant-owned model (it has a `tenant` association: `App`,
  # `Collection`, ...; a `Tenant` row itself, a class such as `App` for `index?`, and a new unsaved
  # record for `create?` do not qualify), and that row's tenant is not the request's tenant.
  def cross_tenant_denial?(error)
    return false unless respond_to?(:current_tenant, true)

    tenant = current_tenant
    record = error.record
    return false if tenant.nil? || !tenant_owned_saved_record?(record)

    record.tenant_id != tenant.id
  end

  def tenant_owned_saved_record?(record)
    return false unless record.respond_to?(:persisted?) && record.persisted?

    record.class.respond_to?(:reflect_on_association) && !record.class.reflect_on_association(:tenant).nil?
  end

  # The message a plain `Model.find(id)` miss would give, so the two answers read alike.
  def cross_tenant_not_found(record)
    name = record.class.name
    ActiveRecord::RecordNotFound.new("Couldn't find #{name} with 'id'=#{record.id}", name, 'id', record.id)
  end

  def not_found(e)
    respond_with_error(404, e)
  end

  def gone(e)
    respond_with_error(410, e)
  end

  def unprocessable_entity(e)
    respond_with_error(422, e)
  end

  def not_acceptable(e)
    respond_with_error(406, e)
  end

  def bad_request(e)
    respond_with_error(400, e)
  end

  def internal_server_error(e)
    respond_with_error(500, e)
  end

  def service_unavailable(e)
    respond_with_error(503, e)
  end

  def respond_with_error(code, exception, **body)
    if code >= 500
      logger.error exception.full_message
      Sentry.capture_exception exception
    end

    respond_to do |format|
      format.any  {
        @code = code
        @exception = exception
        @title = t("errors.code.#{@code}.title")
        @message = exception.message if code < 500

        case exception
        when ActiveRecord::ConnectionNotEstablished
          @message = t('errors.messages.database_connection_error')
        when Pundit::NotAuthorizedError
          policy_name = exception.policy.class.to_s.underscore
          @message = t("#{policy_name}.#{exception.query}", scope: "pundit", default: :default)
        end

        render 'errors/index', status: code, formats: [:html]
      }

      format.json {
        body[:error] ||= exception.message
        if Rails.env.development?
          body[:debug] = { class: exception.class }
          body[:debug][:params] = params
          body[:debug][:backtrace] = exception.backtrace if exception.backtrace.present?
        end

        render json: body, status: code
      }
    end
  end
end
