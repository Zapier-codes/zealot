# frozen_string_literal: true

# Z-P9 (principle 2): the owner's moderation of anonymous reviews. The automated moderator (Z-P9's
# `AnonymousReviewModerator`) holds a suspicious review as `pending`; this page is where a person decides it.
# Publishing makes it public (it reaches the signed index on the next publish); rejecting keeps it out for
# good. A rejected or pending review never reaches a reader.
class Apps::AnonymousReviewsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app
  before_action :set_review, only: %i[publish reject]
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/anonymous_reviews
  def index
    authorize AnonymousReview.new(app: @app), :index?
    @pending = @app.anonymous_reviews.where(status: 'pending').newest_first
    @recent_published = @app.anonymous_reviews.published.newest_first.limit(50)
    @rejected_count = @app.anonymous_reviews.where(status: 'rejected').count
    @title = t('apps.anonymous_reviews.index.title')
  end

  # POST /apps/:app_id/anonymous_reviews/:id/publish
  def publish
    authorize @review, :publish?
    raise_if_app_archived!(@app)

    @review.update!(status: 'published', moderation_reason: nil)
    redirect_to app_anonymous_reviews_path(@app), notice: t('.published')
  end

  # POST /apps/:app_id/anonymous_reviews/:id/reject
  def reject
    authorize @review, :reject?
    raise_if_app_archived!(@app)

    @review.update!(status: 'rejected', moderation_reason: params[:reason].to_s.presence || 'owner_rejected')
    redirect_to app_anonymous_reviews_path(@app), notice: t('.rejected')
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def set_review
    @review = @app.anonymous_reviews.find(params[:id])
  end
end
