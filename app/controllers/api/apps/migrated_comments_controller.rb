# frozen_string_literal: true

# Task 45c: comments an app earned before it was listed here, entered by a platform admin
# (AppPolicy#set_migrated_stats?), user token only. Each comment is its own row and a source note is required on
# it, because these are real history. Adding is all-or-nothing: if one comment is invalid nothing is saved.
#
#   GET    /api/apps/:app_id/migrated_comments      -> 200 the stored comments, oldest first
#   POST   /api/apps/:app_id/migrated_comments      source_note=<text>  comments[][author_name|rating|body|
#                                                   commented_on|helpful_count]  -> 201, or 422 naming the row
#   DELETE /api/apps/:app_id/migrated_comments/:id  -> 204
#
# A `source_note` at the top level applies to every comment that has none of its own. Nothing here is shown with
# a label; the table keeps the carried-over comments apart from live reviews.
class Api::Apps::MigratedCommentsController < Api::BaseController
  MAX_PER_CALL = 200
  COMMENT_FIELDS = %i[author_name rating body commented_on helpful_count source_note].freeze

  before_action :validate_user_token
  before_action :set_app

  def index
    authorize @app, :set_migrated_stats?
    render json: { app_id: @app.id, comments: @app.migrated_comments.order(:commented_on, :id).map { |c| render_comment(c) } }
  end

  def create
    authorize @app, :set_migrated_stats?
    rows = incoming_rows
    return render json: { error: "send 1 to #{MAX_PER_CALL} comments" }, status: :unprocessable_entity if rows.blank? || rows.size > MAX_PER_CALL

    created = []
    MigratedComment.transaction do
      rows.each_with_index do |attrs, index|
        comment = @app.migrated_comments.new(attrs.merge(recorded_by: @current_user))
        unless comment.save
          render json: { error: "comment #{index + 1}: #{comment.errors.full_messages.to_sentence}" }, status: :unprocessable_entity
          raise ActiveRecord::Rollback
        end
        created << comment
      end
    end
    render json: { app_id: @app.id, created: created.map { |c| render_comment(c) } }, status: :created if created.size == rows.size
  end

  def destroy
    authorize @app, :set_migrated_stats?
    @app.migrated_comments.find(params[:id]).destroy!
    head :no_content
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end

  def incoming_rows
    list = params[:comments]
    list = list.values if list.respond_to?(:values) && !list.is_a?(Array)
    Array(list).filter_map do |entry|
      next unless entry.respond_to?(:permit)

      attrs = entry.permit(*COMMENT_FIELDS).to_h.symbolize_keys
      attrs[:source_note] = params[:source_note] if attrs[:source_note].blank?
      attrs
    end
  end

  def render_comment(comment)
    { id: comment.id, author_name: comment.author_name, rating: comment.rating, body: comment.body,
      commented_on: comment.commented_on, helpful_count: comment.helpful_count,
      source_note: comment.source_note, recorded_by_id: comment.recorded_by_id }
  end
end
