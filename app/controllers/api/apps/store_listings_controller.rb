# frozen_string_literal: true

# Task 42e: the API twin of the console's store-listing page (Apps::StoreListingsController), so that
# putting an app on our own store can be done by a script as well as by hand. User token only (the legacy
# `token` parameter, like every `/api` door that reads `validate_user_token`); a per-app token is never read.
# Nothing here adds a rule: each action calls the same model method and the same policy question the console
# calls, so the two paths cannot disagree.
#
#   GET   /api/apps/:app_id/store_listing            -> 200 readiness report (see StoreListingReadiness)
#   POST  /api/apps/:app_id/store_listing            -> 200 report after "request listing" (the owner)
#   PATCH /api/apps/:app_id/store_listing/mark_paid  -> 200 report after go-live (platform admin)
#
# Refusals change nothing: 401/422 no or wrong token, 403 policy, 404 no such app (or an app of another
# tenant), 422 with `error` (and `code` where a caller can act on it): `publisher_profile_required` (the
# owner has no publisher profile; create it in the console), `app_archived`, `listing_not_available` (the app
# is not in the state the transition needs). The request and mark-paid actions are one-way and are not
# idempotent: asking again after a success answers 422 `listing_not_available`.
class Api::Apps::StoreListingsController < Api::BaseController
  before_action :validate_user_token
  before_action :set_app

  def show
    authorize @app, :view_store_listing?
    render json: StoreListingReadiness.call(@app)
  end

  def create
    authorize @app, :list_on_store?
    return render_error('app is archived', 'app_archived') if @app.archived

    profile = current_user.publisher_profile
    return render_error('the owner has no publisher profile', 'publisher_profile_required') if profile.blank?
    return render_error("listing_status is #{@app.listing_status}", 'listing_not_available') unless @app.request_store_listing!(profile)

    render json: StoreListingReadiness.call(@app.reload)
  end

  def mark_paid
    authorize @app, :mark_paid?
    return render_error("listing_status is #{@app.listing_status}", 'listing_not_available') unless @app.go_live!

    render json: StoreListingReadiness.call(@app.reload)
  end

  private

  def set_app
    # A cross-tenant id is simply not found (404), never a 403, as in Admin::AppsController.
    @app = policy_scope(App).find(params[:app_id])
  end

  def render_error(message, code)
    render json: { error: message, code: code, listing_status: @app.listing_status }, status: :unprocessable_entity
  end
end
