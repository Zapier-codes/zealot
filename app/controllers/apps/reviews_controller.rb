# frozen_string_literal: true

# Z-P8 (Play Console parity): the reviews inbox. Play shows an owner every review an app has earned, newest
# first, with a reply box under the ones that need an answer. Zealot's reviews are the carried-over rows in
# `migrated_comments` (Task 45c) plus whatever arrives later; this page lists them and writes the developer
# reply through `MigratedComment#record_developer_reply!`.
#
# The reply is a single text per review (Play allows one, editable), so this is an `edit`/`update`, not a
# growing thread. A blank reply clears it. Nothing here is staged or drafted -- a reply is public the moment
# it is saved, the same as Play, so it rides the app's index publish.
class Apps::ReviewsController < ApplicationController
  include AppArchived

  before_action :authenticate_user!
  before_action :set_app
  before_action :set_comment, only: %i[update]
  before_action -> { set_app_breadcrumbs(app: @app) }

  # GET /apps/:app_id/reviews
  def index
    authorize MigratedComment.new(app: @app), :index?
    load_page
  end

  # PATCH /apps/:app_id/reviews/:id
  def update
    authorize @comment, :update?
    raise_if_app_archived!(@app)

    text = params.dig(:migrated_comment, :developer_reply)
    return head(:bad_request) unless text.is_a?(String)

    if @comment.record_developer_reply!(text)
      redirect_to app_reviews_path(@app), notice: t('.saved')
    else
      @reply_error = @comment.errors.full_messages.to_sentence
      @reply_comment_id = @comment.id
      load_page
      flash.now[:alert] = t('.refused', reasons: @reply_error)
      render :index, status: :unprocessable_entity
    end
  end

  private

  def set_app
    @app = App.find(params[:app_id])
  end

  def set_comment
    @comment = @app.migrated_comments.find(params[:id])
  end

  def load_page
    @reviews = @app.migrated_comments.order(commented_on: :desc, id: :desc)
    @replied_count = @reviews.count(&:replied?)
    @average_rating = @reviews.any? ? (@reviews.sum(&:rating).to_f / @reviews.size).round(2) : nil
    @title = t('apps.reviews.index.title')
  end
end
