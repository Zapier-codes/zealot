# frozen_string_literal: true

# Z-P18 (SCIM half, Play Console parity): the SCIM 2.0 provisioning endpoints an identity provider calls to
# create, read, update and de-provision people. Play Console's enterprise tier is driven this way; this is the
# server half and `ScimToken` is the credential.
#
# Auth is the bearer token ONLY (`Authorization: Bearer zsc_...`), never a query parameter, and never a user
# token: a SCIM token is the scoped credential an IdP holds, and it is the only way in. The token decides the
# tenant -- a tenant-scoped token can only touch members of its own tenant; a platform-scoped token (default
# host) can touch anyone. Every write records an `AuditEntry`.
#
# Mounted at /scim/v2 (see config/routes.rb), routes: Users index/show/create/update/delete plus the
# ServiceProviderConfig/Schemas/ResourceTypes discovery documents a SCIM client reads before it provisions.
# A malformed filter answers SCIM's own error envelope (RFC 7644 section 3.12), not a Rails one.
module Scim
  class UsersController < ActionController::API
    include ActionView::Helpers::TranslationHelper

    before_action :authenticate_scim_token
    before_action :set_scim_user, only: %i[show update destroy]

    # GET /scim/v2/Users
    def index
      scope = user_scope
      total = scope.count
      page = paginate(scope)

      resources = page.map { |user| Scim::UserMapper.to_resource(user, tenant: @scim_tenant) }
      render json: Scim::UserMapper.list_response(
        resources, total: total, start_index: start_index, items_per_page: page.size
      ), status: :ok
    end

    # GET /scim/v2/Users/:id
    def show
      render json: Scim::UserMapper.to_resource(@scim_user, tenant: @scim_tenant), status: :ok
    end

    # POST /scim/v2/Users
    def create
      result = provisioner.create(Scim::UserMapper.attributes_from(payload))
      return scim_error(:invalid_value, result.errors, status: :bad_request) unless result.ok?

      audit(result.created ? 'created' : 'updated', result.user)
      render json: Scim::UserMapper.to_resource(result.user, tenant: @scim_tenant, membership: result.membership),
             status: result.created ? :created : :ok
    end

    # PUT/PATCH /scim/v2/Users/:id
    def update
      result = provisioner.update(@scim_user, Scim::UserMapper.attributes_from(payload))
      return scim_error(:invalid_value, result.errors, status: :bad_request) unless result.ok?

      audit('updated', @scim_user)
      render json: Scim::UserMapper.to_resource(@scim_user, tenant: @scim_tenant), status: :ok
    end

    # DELETE /scim/v2/Users/:id — de-provision, idempotent.
    def destroy
      provisioner.deactivate(@scim_user)
      audit('destroyed', @scim_user)
      head :no_content
    end

    # GET /scim/v2/ServiceProviderConfig — the discovery document an IdP reads. We support PATCH, filtering and
    # `active` on the User resource; we do not do bulk or an ETag-based change-password.
    def service_provider_config
      render json: {
        'schemas' => ['urn:ietf:params:scim:schemas:core:2.0:ServiceProviderConfig'],
        'documentationUri' => nil,
        'patch' => { 'supported' => true },
        'bulk' => { 'supported' => false, 'maxOperations' => 0, 'maxPayloadSize' => 0 },
        'filter' => { 'supported' => true, 'maxResults' => max_results },
        'changePassword' => { 'supported' => false },
        'sort' => { 'supported' => false },
        'etag' => { 'supported' => false },
        'authenticationSchemes' => [
          {
            'type' => 'oauthbearertoken',
            'name' => 'OAuth Bearer Token',
            'description' => 'Authentication scheme using the OAuth Bearer Token standard',
            'primary' => true
          }
        ],
        'meta' => { 'resourceType' => 'ServiceProviderConfig', 'location' => '/scim/v2/ServiceProviderConfig' }
      }, status: :ok
    end

    def schemas
      render json: {
        'schemas' => ['urn:ietf:params:scim:api:messages:2.0:ListResponse'],
        'totalResults' => 1,
        'itemsPerPage' => 1,
        'startIndex' => 1,
        'Resources' => [
          {
            'id' => Scim::UserMapper::USER_SCHEMA,
            'name' => 'User',
            'description' => 'User Account',
            'attributes' => [],
            'meta' => { 'resourceType' => 'Schema', 'location' => "/scim/v2/Schemas/#{Scim::UserMapper::USER_SCHEMA}" }
          }
        ]
      }, status: :ok
    end

    def resource_types
      render json: {
        'schemas' => ['urn:ietf:params:scim:api:messages:2.0:ListResponse'],
        'totalResults' => 1,
        'itemsPerPage' => 1,
        'startIndex' => 1,
        'Resources' => [
          {
            'id' => 'User',
            'name' => 'User',
            'endpoint' => '/Users',
            'schema' => Scim::UserMapper::USER_SCHEMA,
            'meta' => { 'resourceType' => 'ResourceType', 'location' => '/scim/v2/ResourceTypes/User' }
          }
        ]
      }, status: :ok
    end

    private

    # Read the bearer token, find the live SCIM token, set the tenant from it. One generic 401 on any failure,
    # never saying which check failed. `record_use!` stamps last-used (throttled) so an operator can see a
    # token is still in use.
    def authenticate_scim_token
      secret = presented_bearer_token
      token = secret && ScimToken.authenticate(secret)
      return scim_unauthorized if token.nil?

      token.record_use!
      @scim_token = token
      @scim_tenant = token.tenant
    end

    def presented_bearer_token
      match = Api::AppTokenAuth::BEARER_HEADER.match(request.authorization.to_s)
      secret = match && match[1]
      return nil if secret.blank? || secret.length > 128

      secret
    end

    def scim_unauthorized
      response.headers['WWW-Authenticate'] = 'Bearer'
      scim_error(:unauthorized, [t('scim.unauthorized')], status: :unauthorized)
    end

    def provisioner
      @provisioner ||= Scim::Provisioner.new(tenant: @scim_tenant)
    end

    # Users this token may see: a tenant token sees only that tenant's members; a platform token sees everyone.
    # The optional SCIM `filter` is applied on top (only `userName`/`emails.value` eq is supported, which is
    # all an IdP needs to look a person up before provisioning).
    def user_scope
      base = if @scim_tenant
               User.where(id: TenantMembership.where(tenant_id: @scim_tenant.id).select(:user_id))
             else
               User.all
             end
      filtered = apply_filter(base)
      filtered.order(:id)
    end

    def apply_filter(relation)
      raw = params[:filter].to_s.strip
      return relation if raw.blank?

      match = raw.match(/\A\s*(userName|emails\.value|externalId)\s+eq\s+"([^"]*)"\s*\z/i)
      return relation.none if match.nil? # an unsupported filter matches nothing, rather than everything

      value = match[2].downcase
      relation.where('LOWER(email) = ?', value)
    end

    def paginate(relation)
      relation.limit(page_size).offset([start_index - 1, 0].max)
    end

    def start_index
      [params[:startIndex].to_i, 1].max
    end

    def page_size
      requested = params[:count].to_i
      requested = max_results if requested <= 0
      [requested, max_results].min
    end

    def max_results
      100
    end

    def set_scim_user
      @scim_user = user_scope.find_by(id: params[:id])
      scim_error(:not_found, [t('scim.user_not_found')], status: :not_found) if @scim_user.nil?
    end

    def payload
      params.permit!.to_h.symbolize_keys.transform_keys(&:to_s)
    end

    # SCIM error envelope (RFC 7644 section 3.12).
    def scim_error(scim_type, detail, status:)
      render json: {
        'schemas' => ['urn:ietf:params:scim:api:messages:2.0:Error'],
        'detail' => Array(detail).join(', '),
        'status' => Rack::Utils.status_code(status).to_s,
        'scimType' => scim_type.to_s
      }, status: status
    end

    # Z-P18: the audit log entry for every SCIM change, naming the token (by its last four, never the secret)
    # and the subject. Uses the record's [type, id] pair so a de-provisioned (but not destroyed) account is
    # still named.
    def audit(action, user)
      AuditEntry.record(
        action: action,
        subject: [user.class.name, user.id],
        actor: nil,
        tenant: @scim_tenant,
        summary_i18n_key: 'scim.audit_entries.summary',
        summary: "scim #{action} user=#{user.email} token=#{@scim_token.last_four}",
        metadata: { kind: action, token_last_four: @scim_token.last_four, tenant: @scim_tenant&.tenant_id }
      )
    end
  end
end
