# frozen_string_literal: true

# Task 45a: downloads and ratings an app earned before it was listed here (for example from a manual
# distribution), entered by a platform admin (AppPolicy#set_migrated_stats?), user token only. The figures are
# real history, so a source note is required with any non-zero figure and who entered them and when is
# recorded. Like the editorial flags, this SETS the values sent, so repeating a call is harmless; a change
# republishes the catalog index through App's own after_commit.
#
#   GET /api/apps/:app_id/migrated_stats  -> 200 the stored figures and who recorded them
#   PUT /api/apps/:app_id/migrated_stats  downloads=<n>  rating_average=<1..5>  rating_count=<n>
#                                         source_note=<text>   (send only what changes)  -> 200, or 422
#
# D-Store sees only the neutral `base_stats` in the index and adds its own counts; nothing here is shown with a
# label. The columns keep the carried-over part apart so a total can always be split again.
class Api::Apps::MigratedStatsController < Api::BaseController
  FIELDS = { 'downloads' => :migrated_downloads, 'rating_average' => :migrated_rating_average,
             'rating_count' => :migrated_rating_count, 'source_note' => :migrated_source_note }.freeze

  before_action :validate_user_token
  before_action :set_app

  def show
    authorize @app, :set_migrated_stats?
    render json: report
  end

  def update
    authorize @app, :set_migrated_stats?
    attrs = FIELDS.select { |param, _| params.key?(param) }.to_h { |param, column| [column, params[param].presence] }
    if attrs.empty?
      return render json: { error: 'send downloads, rating_average, rating_count and/or source_note' },
                    status: :unprocessable_entity
    end

    attrs[:migrated_downloads] ||= 0 if attrs.key?(:migrated_downloads)
    attrs[:migrated_rating_count] ||= 0 if attrs.key?(:migrated_rating_count)
    # A count of zero means no ratings, so the average goes too (the model refuses an average with no count).
    attrs[:migrated_rating_average] = nil if attrs.key?(:migrated_rating_count) && attrs[:migrated_rating_count].to_i.zero?
    attrs.merge!(migrated_recorded_by_id: @current_user.id, migrated_recorded_at: Time.current)
    @app.update!(attrs)
    render json: report
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end

  def report
    { app_id: @app.id, downloads: @app.migrated_downloads, rating_average: @app.migrated_rating_average&.to_f,
      rating_count: @app.migrated_rating_count, source_note: @app.migrated_source_note,
      recorded_by_id: @app.migrated_recorded_by_id, recorded_at: @app.migrated_recorded_at }
  end
end
