# frozen_string_literal: true

# Task 25: an app's listing on our own stores — the owner asks to publish,
# then it waits for payment, then it is live. Singular resource under an app
# (config/routes.rb: `resource :store_listing`).
#
# Payment itself isn't connected yet (provider not chosen). Until it is,
# `mark_paid` lets an admin record the payment by hand; the payment slice will
# call App#go_live! instead and this action goes away.
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

  # PATCH /apps/:app_id/store_listing/mark_paid — admin, temporary.
  def mark_paid
    authorize @app, :mark_paid?

    if @app.go_live!
      redirect_to app_store_listing_path(@app), notice: t('.notice')
    else
      redirect_to app_store_listing_path(@app), alert: t('.not_available')
    end
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end
end
