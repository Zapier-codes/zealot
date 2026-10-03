# frozen_string_literal: true

# Task 34d-1 (D-Store leaf 35, `7.a.xi.zi`): the user token from the `Authorization: Bearer <user token>` header
# ONLY, for the controllers that ask for it. The older `Api::BaseController#validate_user_token` reads
# `params[:token]`, which on a GET is a query string (logged, kept in history); decision 34-1 calls that
# a known weakness and says a new path must not accept it. That older path is left exactly as it is (the
# operator's call, decision 34-2); this is a second, stricter door for the admin-only signing-key API
# and the token-minting API, which handle secrets and should never see a credential in a URL.
#
# OPT-IN, closed by default, like Api::AppTokenAuth: including this concern changes nothing until a
# controller declares `before_action :validate_user_token_header` itself.
#
# What it checks, on every request: the header is a bearer header, its value is NOT a `zpa_` per-app token
# (an app token can never open these doors, decision 34-4), it is the token of an existing user, and that
# user is not `access_locked?` (the check the older path lacks, decision 34-2's "new path must check it").
# Any failure is one 401 with one generic message and a `WWW-Authenticate: Bearer` header; the answer never
# says which check failed. Authorization (who may do what) stays with Pundit in the controller.
module Api::UserTokenHeaderAuth
  extend ActiveSupport::Concern

  # A real user token is 32 hex characters (User#generate_user_token). The cap only keeps an absurd
  # header from being sent to the database as a lookup value.
  USER_TOKEN_MAX_LENGTH = 128

  private

  # The value of an `Authorization: Bearer ...` header that is not a per-app token, or nil. Reuses the
  # app-token concern's header pattern so the two parsers cannot drift apart.
  def presented_user_token
    match = Api::AppTokenAuth::BEARER_HEADER.match(request.authorization.to_s)
    secret = match && match[1]
    return nil if secret.blank? || secret.length > USER_TOKEN_MAX_LENGTH
    return nil if secret.start_with?(AppApiToken::PREFIX)

    secret
  end

  # before_action. Sets `@current_user` (what Pundit reads through Api::BaseController#current_user) on
  # success; renders the generic 401 and halts the chain otherwise.
  def validate_user_token_header
    secret = presented_user_token
    user = secret && User.find_by(token: secret)
    return render_user_token_unauthorized if user.nil? || user.access_locked?

    @current_user = user
  end

  def render_user_token_unauthorized
    response.headers['WWW-Authenticate'] = 'Bearer'
    render json: { error: t('api.unauthorized_token') }, status: :unauthorized
  end
end
