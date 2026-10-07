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
#   POST  /api/apps/:app_id/store_listing/pay        -> 201 starts the B-PAY listing-fee payment (the owner)
#   GET   /api/apps/:app_id/store_listing/payment    -> 200 the listing-fee payments and their status
#
# Task 42f, paying: `pay` creates a `pending` Payment and a B-PAY payment (StoreListingPayment, the same code the
# console's pay page runs) and answers with `client_secret`, `publishable_key` and `sdk_url`: what B-PAY's own
# checkout needs to take the card. Zealot never sees card data and never confirms a charge. The app goes live
# only when B-PAY's signed webhook reports success; poll `payment` (or the report's `listing_status`) for that.
# An optional `return_url` (http or https) is where B-PAY sends the browser after a redirect-based check; it
# defaults to the console's listing page. Each call to `pay` makes a new pending Payment (the client secret
# cannot be read back), so do not call it in a retry loop. 503 `payment_not_configured` when B-PAY's API key is
# unset, 502 `payment_start_failed` when B-PAY refused (the Payment row is kept as `failed`).
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
    return if incomplete_listing_refused?(draft_only: true)
    return render_error("listing_status is #{@app.listing_status}", 'listing_not_available') unless @app.request_store_listing!(profile)

    render json: StoreListingReadiness.call(@app.reload)
  end

  def mark_paid
    authorize @app, :mark_paid?
    return render_error("listing_status is #{@app.listing_status}", 'listing_not_available') unless @app.go_live!

    render json: StoreListingReadiness.call(@app.reload)
  end

  def pay
    authorize @app, :list_on_store?
    return render_error('app is archived', 'app_archived') if @app.archived
    return render_error("listing_status is #{@app.listing_status}", 'listing_not_available') unless @app.listing_awaiting_payment?
    return if incomplete_listing_refused?

    unless HyperswitchClient.configured?
      return render json: { error: 'payment is not configured on this server', code: 'payment_not_configured' },
                    status: :service_unavailable
    end

    return_url = checkout_return_url
    return render_error('return_url must be an http or https URL', 'invalid_return_url') unless return_url

    render json: checkout_json(StoreListingPayment.start(app: @app, user: current_user, return_url: return_url)),
           status: :created
  rescue StoreListingPayment::StartFailed
    render json: { error: 'B-PAY did not start the payment', code: 'payment_start_failed' }, status: :bad_gateway
  end

  def payment
    authorize @app, :view_store_listing?
    payments = @app.payments.where(purpose: 'listing_fee').order(id: :desc).limit(5)
    render json: { listing_status: @app.listing_status, payments: payments.map { |row| StoreListingReadiness.payment_json(row) } }
  end

  private

  # Task 43b-2: the publish gate. Before a request or a payment, the icon and 2 screenshots must exist
  # (`ListingRequirements`); an already-listed app is exempt there. Answers 422 `listing_incomplete` with the
  # list and changes nothing. `draft_only` keeps a non-draft app's request answering `listing_not_available`.
  def incomplete_listing_refused?(draft_only: false)
    return false if draft_only && !@app.listing_draft?

    missing = ListingRequirements.call(@app)
    return false if missing.empty?

    render json: { error: "the store listing is incomplete: #{ListingRequirements.sentence(missing)}",
                   code: 'listing_incomplete', missing: missing.as_json, listing_status: @app.listing_status },
           status: :unprocessable_entity
    true
  end

  def checkout_return_url
    given = params[:return_url].to_s.strip
    return app_store_listing_url(@app) if given.blank?

    uri = URI.parse(given)
    given if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  def checkout_json(started)
    StoreListingReadiness.payment_json(started.payment).merge(
      list_price_cents: StoreListingPayment::LIST_PRICE_CENTS,
      checkout_url: store_listing_checkout_url(token: started.payment.checkout_token),
      confirm_url: "#{HyperswitchClient.api_url}/payments/#{started.payment.hyperswitch_payment_id}/confirm",
      checkout_expires_at: Payment::CHECKOUT_TTL.from_now,
      client_secret: started.client_secret,
      publishable_key: StoreListingPayment.publishable_key,
      sdk_url: StoreListingPayment.sdk_url
    )
  end

  def set_app
    # A cross-tenant id is simply not found (404), never a 403, as in Admin::AppsController.
    @app = policy_scope(App).find(params[:app_id])
  end

  def render_error(message, code)
    render json: { error: message, code: code, listing_status: @app.listing_status }, status: :unprocessable_entity
  end
end
