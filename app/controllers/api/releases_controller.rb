# frozen_string_literal: true

class Api::ReleasesController < Api::BaseController
  before_action :validate_user_token
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
    authorize @release
  end

  def release_params
    params.permit(
      :release_version, :build_version, :release_type, :source, :branch, :git_commit,
      :ci_url, :custom_fields, :changelog
    )
  end
end
