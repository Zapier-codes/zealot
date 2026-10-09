# frozen_string_literal: true

# Task 47e: the API twin of the "Automatic in-app updates" checkbox on the app's edit page (Task 47's publisher
# switch, `apps.updater_enabled`). Whoever may update the app (AppPolicy#update?: admin, owner or a manage
# collaborator, plus the tenant rule) may read and set it. User token only, like the other app settings.
#
#   GET /api/apps/:app_id/updater              -> 200 { app_id, enabled }
#   PUT /api/apps/:app_id/updater  enabled=<true|false>   -> 200 the stored value, or 422
#
# Setting it repeats harmlessly. It does not republish the catalog index (the flag is not in the index) and it
# changes no release that already exists: the injection step reads it when a release is built (47c), so a
# change applies from the next release.
class Api::Apps::UpdaterController < Api::BaseController
  before_action :validate_user_token
  before_action :set_app

  def show
    authorize @app, :update?
    render json: report
  end

  def update
    authorize @app, :update?
    value = params[:enabled].to_s.strip.downcase
    return render json: { error: 'send enabled=true or enabled=false' }, status: :unprocessable_entity unless %w[true false].include?(value)

    @app.update!(updater_enabled: value == 'true')
    render json: report
  end

  private

  def set_app
    @app = policy_scope(App).find(params[:app_id])
  end

  def report
    { app_id: @app.id, enabled: @app.updater_enabled }
  end
end
