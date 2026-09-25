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

    payment = Payment.create!(app: @app, user: current_user, purpose: 'listing_fee',
                              amount_cents: 1499, currency: 'usd', status: 'pending')

    begin
      result = HyperswitchClient.create_payment(
        amount_cents: payment.amount_cents, currency: payment.currency,
        customer_id: "app-#{@app.id}", return_url: app_store_listing_url(@app),
        setup_future_usage: 'off_session', metadata: { app_id: @app.id, payment_id: payment.id }
      )
    rescue HyperswitchClient::Error => e
      Rails.logger.error("[Apps::StoreListingsController#pay] #{e.class}: #{e.message}")
      payment.mark_failed!(raw: e.message)
      return redirect_to app_store_listing_path(@app), alert: t('.payment_start_failed')
    end

    payment.update!(hyperswitch_payment_id: result.payment_id)

    # ⚠️ Not a finished checkout flow — see handover.md's Task 32 entry.
    # B-PAY/Hyperswitch confirms a payment client-side (Hyperswitch.js +
    # the returned client_secret), which is not wired up here: building
    # that against unconfirmed client-integration details would mean
    # guessing at a payment form, which this codebase does not do. This
    # renders a minimal page carrying @client_secret for whoever picks up
    # that slice next.
    @client_secret = result.client_secret
    @title = t('.title')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end
end
