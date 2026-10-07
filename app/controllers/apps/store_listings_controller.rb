# frozen_string_literal: true

# Task 25: an app's listing on our own stores — the owner asks to publish,
# then it waits for payment, then it is live. Singular resource under an app
# (config/routes.rb: `resource :store_listing`).
#
# Task 32: payment is now connected (B-PAY/Hyperswitch, see #pay and
# HyperswitchClient). `mark_paid` stays as an admin fallback until the real
# checkout is verified end-to-end — see #pay's own comment.
class Apps::StoreListingsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/store_listing
  def show
    authorize @app, :view_store_listing?
    @title = t('.title')
    @profile = @app.publisher_profile || @app.owner&.user&.publisher_profile
    # Task 43b-4: what the publish gate (43b-2) would refuse for; the page shows it and disables the buttons.
    @missing = ListingRequirements.call(@app)
  end

  # POST /apps/:app_id/store_listing — the owner asks to publish.
  def create
    authorize @app, :list_on_store?
    raise_if_app_archived!(@app)

    profile = current_user.publisher_profile
    if profile.blank?
      return redirect_to new_publisher_profile_path(return_to: app_store_listing_path(@app)),
                         notice: t('.need_profile')
    end

    if @app.listing_draft? && (missing = ListingRequirements.call(@app)).any?
      return redirect_to app_store_listing_path(@app), alert: t('.incomplete', missing: missing_sentence(missing))
    end

    if @app.request_store_listing!(profile)
      redirect_to app_store_listing_path(@app), notice: t('.requested')
    else
      redirect_to app_store_listing_path(@app), alert: t('.not_available')
    end
  end

  # PATCH /apps/:app_id/store_listing/mark_paid — admin, temporary. Left in
  # place alongside `pay` below (Task 32) until B-PAY checkout is verified
  # end-to-end — see HyperswitchWebhooksController's class comment for why.
  def mark_paid
    authorize @app, :mark_paid?

    if @app.go_live!
      redirect_to app_store_listing_path(@app), notice: t('.notice')
    else
      redirect_to app_store_listing_path(@app), alert: t('.not_available')
    end
  end

  # POST /apps/:app_id/store_listing/pay — Task 32, the real payment path.
  # Creates a Payment and starts a B-PAY checkout with setup_future_usage
  # so the same charge also creates a mandate for the recurring maintenance
  # fee. Does NOT call App#go_live! itself — only the signed webhook
  # (HyperswitchWebhooksController) does that, once B-PAY actually confirms
  # the charge, per this app's existing "never trust the redirect alone"
  # rule (see PlayCredential-adjacent precedent elsewhere in this file).
  def pay
    authorize @app, :list_on_store?
    unless @app.listing_awaiting_payment?
      return redirect_to app_store_listing_path(@app), alert: t('.not_available')
    end

    if (missing = ListingRequirements.call(@app)).any?
      return redirect_to app_store_listing_path(@app), alert: t('.incomplete', missing: missing_sentence(missing))
    end

    begin
      started = StoreListingPayment.start(app: @app, user: current_user, return_url: pay_app_store_listing_url(@app))
    rescue StoreListingPayment::StartFailed
      return redirect_to app_store_listing_path(@app), alert: t('.payment_start_failed')
    end

    # Unified Checkout embed (app/views/apps/store_listings/pay.html.slim) —
    # real Hyperswitch client-side API (Hyper(), widgets(), confirmPayment(),
    # retrievePayment() on return), grounded in Hyperswitch's own
    # open-source web-client integration docs, not guessed. return_url
    # points back at this same action so the post-redirect status check
    # (payment_intent_client_secret in the query string) has the same page
    # to land on. Two values only the operator can supply, both documented
    # in handover.md's payment-listing-fee Task 32 entry: the publishable
    # key (Control Center -> Developer -> API Keys) and the *web client*
    # URL — self-hosted Hyperswitch serves HyperLoader.js from a separately
    # deployed "web client" component, not from B-PAY's API host, per
    # Hyperswitch's own open-source deployment docs.
    @client_secret = started.client_secret
    @publishable_key = StoreListingPayment.publishable_key
    @sdk_url = StoreListingPayment.sdk_url
    @title = t('.title')
  end

  private

  # Task 43b-2: "no icon; 1 of 2 screenshots" in the viewer's language.
  def missing_sentence(missing)
    missing.map do |item|
      item.key == :screenshots ? t('apps.store_listings.missing.screenshots', count: item.count, target: item.target) : t('apps.store_listings.missing.icon')
    end.to_sentence
  end

  def set_app
    @app = App.find(params[:app_id])
  end
end
