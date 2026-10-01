# frozen_string_literal: true

class Api::ReleasesController < Api::BaseController
  # Task 34a-6 (Storeapp leaf `f.xiv`): `release` is the ONE action here that accepts a per-app token
  # (`Authorization: Bearer zpa_...`, see Api::AppTokenAuth). update and destroy stay user-token only:
  # a zpa_ header on them is ignored and they answer exactly as before.
  before_action :validate_app_token, only: :release, if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_release_request?
  before_action :set_release

  # UPDATE /releases/:id
  def update
    @release.update!(release_params)
    render json: @release
  end

  # DELETE /releases/:id
  def destroy
    @release.destroy
    render json: { mesage: 'OK' }
  end

  # Task 34a-6: POST /api/releases/:id/release -- make a held release available (the API twin of the
  # console's `hold -> available` move, 27f-b). Only a HELD release can be released this way: the
  # check reads the same `Release::STATUS_TRANSITIONS` table the console uses (the move to `available`
  # must be named `release`), so a halted release (that is `resume`) or a pulled one (`restore`) is
  # refused here and stays a console action. Saving the new status republishes the owning tenant's
  # catalog index through 27f-a's `after_update_commit`, so nothing is published from this action.
  #
  # @param id [Integer] required release id
  # @return [JSON] the release, status `available`
  def release
    if @release.app.archived
      return render json: { error: t('api.release_app_archived') }, status: :unprocessable_entity
    end

    unless @release.status_actions['available'] == 'release'
      return render json: { error: t('api.release_not_held', status: @release.status) },
                    status: :unprocessable_entity
    end

    @release.update!(status: 'available')
    render json: @release
  end

  protected

  # Task 23: this controller never authorized anything, so any token holder
  # could edit or delete any release of any app (PUT/DELETE /api/releases/:id).
  # update?/destroy? now go through ReleasePolicy (admin, app owner or a manage
  # collaborator of the release's app).
  # Task 37b-iii-s7c-5b: the lookup goes through the policy scope, so on a tenant's host another
  # tenant's (or the default catalog's) release id is a plain 404, never a 403 that would confirm
  # it exists. On the default host the scope is `Release.all`: unchanged.
  def set_release
    @release = policy_scope(Release).find(params[:id])
    # Task 34a-6: a token is confined to its own app before any policy runs, so another app's release
    # is a 403 (`require_app_token_for!`), never an answer that depends on what the creator can manage.
    return require_app_token_for!(@release.app) if @app_token && @release.app&.id != @app_token.app_id

    # `release` has no predicate of its own: it is the console's status move, so it asks the same
    # question the console asks (ReleasePolicy#update_status?). Pundit would otherwise ask `release?`.
    authorize @release, (action_name == 'release' ? :update_status? : nil)
  end

  # True only for POST .../release carrying a `zpa_` bearer header; every other request keeps the
  # user-token check it always had.
  def app_token_release_request?
    action_name == 'release' && app_token_presented?
  end

  def release_params
    params.permit(
      :release_version, :build_version, :release_type, :source, :branch, :git_commit,
      :ci_url, :custom_fields, :changelog
    )
  end
end
