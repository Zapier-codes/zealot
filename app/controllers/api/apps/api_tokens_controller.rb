# frozen_string_literal: true

# Task 34d-2 (D-Store leaf 36, `7.a.xi.zo`): create, list and revoke an app's per-app API tokens (AppApiToken,
# 34a-1) over the API, so a bootstrap script can make Storeapp's CI token instead of an owner clicking it
# out on the 34a-7 screen (Apps::ApiTokensController). The rules are that screen's, not new ones.
#
#   GET    /api/apps/:app_id/api_tokens        the app's tokens (no secrets), newest first, at most 100
#   POST   /api/apps/:app_id/api_tokens        name (required), expiry ('30' | '90' | '365' | 'none', default '90')
#   DELETE /api/apps/:app_id/api_tokens/:id    revoke (soft: the row stays for the audit log, 34c)
#
# Credentials: the user token from `Authorization: Bearer <token>` ONLY (Api::UserTokenHeaderAuth). A
# per-app `zpa_` token can NEVER open this door (decision 34-4: "creating, listing or revoking tokens" is
# never available to an app token), and `?token=` is not read. The token that is created acts as the user
# who made it (decision 34-2), so it is made under the caller's own account and keeps working only while
# that account can still manage the app.
#
# Who may call: the same rule as the console screen (AppApiTokenPolicy: admin, owner or a manage
# collaborator, plus the tenant rule). The app is looked up through `scoped_apps`, so on a tenant's host
# another tenant's app id is a plain 404.
#
# The secret is in the answer to POST and nowhere else: it is shown once and cannot be read back (decision
# 34-1). The answer is `no-store` (Api::BaseController sets it). The 10-live-tokens cap, the name length
# and the expiry rules are AppApiToken's; a refusal is the base controller's 422 with the model's messages.
class Api::Apps::ApiTokensController < Api::BaseController
  include Api::UserTokenHeaderAuth
  include AppArchived

  # The same choices the console screen offers, read from there so there is one definition.
  EXPIRY_CHOICES = ::Apps::ApiTokensController::EXPIRY_CHOICES
  DEFAULT_EXPIRY = ::Apps::ApiTokensController::DEFAULT_EXPIRY
  LIST_LIMIT = 100

  before_action :validate_user_token_header
  before_action :set_app

  # GET /api/apps/:app_id/api_tokens
  def index
    authorize AppApiToken.new(app: @app), :index?

    tokens = @app.api_tokens.order(created_at: :desc).limit(LIST_LIMIT)
    render json: {
      tokens: tokens.map { |token| token_json(token) },
      live_count: @app.api_tokens.live.count,
      max_live: AppApiToken::MAX_LIVE_PER_APP
    }
  end

  # POST /api/apps/:app_id/api_tokens
  def create
    authorize AppApiToken.new(app: @app), :create?
    raise_if_app_archived!(@app)

    name = params[:name]
    expiry = params[:expiry].to_s.presence || DEFAULT_EXPIRY
    unless name.is_a?(String) && EXPIRY_CHOICES.key?(expiry)
      return render json: { error: t('api.api_token_params_invalid', choices: EXPIRY_CHOICES.keys.to_sentence) },
                    status: :unprocessable_entity
    end

    issued = AppApiToken.issue!(
      app: @app, name: name.strip, created_by: current_user,
      expires_at: EXPIRY_CHOICES[expiry]&.from_now
    )
    audit('created', issued.token)
    render json: token_json(issued.token).merge(secret: issued.secret), status: :created
  end

  # DELETE /api/apps/:app_id/api_tokens/:id
  def destroy
    token = @app.api_tokens.find(params[:id])
    authorize token, :destroy?
    raise_if_app_archived!(@app)

    token.revoke!
    audit('revoked', token)
    render json: token_json(token)
  end

  private

  def set_app
    @app = scoped_apps.find(params[:app_id])
  end

  # Everything but the secret (which only `create` adds, once). `live` is the model's own definition.
  def token_json(token)
    {
      id: token.id,
      name: token.name,
      last_four: token.last_four,
      scopes: token.scopes,
      expires_at: token.expires_at,
      revoked_at: token.revoked_at,
      last_used_at: token.last_used_at,
      created_at: token.created_at,
      live: token.live?
    }
  end

  # One log line per change: who, which app, which token (by id and last four), never the secret. A
  # stand-in until the audit log of Task 34c exists.
  def audit(what, token)
    Rails.logger.info("[app_api_token] #{what} by user=#{current_user.id} app=#{@app.id} token=#{token.id} last_four=#{token.last_four}")
  end
end
