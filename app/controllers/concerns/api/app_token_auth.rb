# frozen_string_literal: true

# Task 34a-2 (Storeapp leaf `f.xiv`): the `/api` accepts a per-app token (AppApiToken), from the
# `Authorization: Bearer zpa_...` header ONLY, for its own app ONLY, acting as the user who created it.
# This is a second auth path next to `validate_user_token`; it shares nothing with it and with the
# session-cookie console. A token can never open a console page (those need a session), and the
# `?token=` user token is never read here.
#
# OPT-IN, closed by default. Including this concern changes nothing: no action is reachable with an app
# token until its controller declares `before_action :validate_app_token` itself (and, for a route that
# takes an app or a channel, calls `require_app_token_for!(app)`). Today exactly one controller does
# (Api::Apps::VersionsController#index, read-only), to prove the path. A route that is not opted in
# answers an app token exactly as it answers any request without a user token.
#
# What `validate_app_token` checks, on EVERY request, never cached:
#   1. the secret is a live token (not malformed, unknown, revoked or expired) and carries the scope
#      the controller needs (`required_app_token_scope`, `publish` unless it overrides it);
#   2. its creator still exists and is not `access_locked?`;
#   3. the creator still passes `AppPolicy#update?` for the token's app, which is `manage?(app:)` plus
#      the tenant rule (a member of the request's tenant, and an app of that tenant; on the default
#      host both are always true, as for the console).
# Any failure is one 401 with one generic message and a `WWW-Authenticate: Bearer` header: the answer
# never says which check failed. Fail closed: if the creator lost access, the token stops working
# (decision 34-2); the owner issues a new one under someone who still has access.
#
# A token for another app is a 403 (`require_app_token_for!`), not a 401: the token is valid, it is
# just not for that app.
module Api::AppTokenAuth
  extend ActiveSupport::Concern

  BEARER_HEADER = /\ABearer[ \t]+(\S+)[ \t]*\z/i

  private

  # The secret in an `Authorization: Bearer zpa_...` header, or nil. A header that is not a bearer
  # header, or whose value does not start with the `zpa_` prefix, is NOT an app token and is ignored
  # here (an endpoint that never read `Authorization` before keeps ignoring it); nothing falls back from
  # a presented-but-bad app token to another credential, see `app_token_presented?` callers.
  def presented_app_token_secret
    match = BEARER_HEADER.match(request.authorization.to_s)
    secret = match && match[1]
    secret if secret&.start_with?(AppApiToken::PREFIX)
  end

  def app_token_presented?
    presented_app_token_secret.present?
  end

  # A controller that needs a different scope overrides this. Opting in is the allowlist (decision 34-4).
  def required_app_token_scope
    AppApiToken::PUBLISH_SCOPE
  end

  # before_action for an opted-in controller. Sets `@app_token` and `@current_user` (the creator) on
  # success; renders the generic 401 and halts the chain otherwise.
  def validate_app_token
    token = AppApiToken.authenticate(presented_app_token_secret)
    user = token&.created_by
    return render_app_token_unauthorized unless token&.scope?(required_app_token_scope)
    return render_app_token_unauthorized unless app_token_acting_user_ok?(user, token.app)

    token.record_use!
    @app_token = token
    @current_user = user
  end

  # Call once the controller knows which app the request is about (an app id, a channel, a release).
  def require_app_token_for!(app)
    return if @app_token && app && app.id == @app_token.app_id

    render json: { error: t('api.app_token_wrong_app') }, status: :forbidden
  end

  def app_token_acting_user_ok?(user, app)
    return false if user.nil? || app.nil?
    return false if user.access_locked?

    AppPolicy.new(user, app).update?
  end

  def render_app_token_unauthorized
    response.headers['WWW-Authenticate'] = 'Bearer'
    render json: { error: t('api.unauthorized_app_token') }, status: :unauthorized
  end
end
