# frozen_string_literal: true

class Api::ReleasesController < Api::BaseController
  # Task 34a-6 (Storeapp leaf `f.xiv`): `release` is the ONE action here that accepts a per-app token
  # (`Authorization: Bearer zpa_...`, see Api::AppTokenAuth). update and destroy stay user-token only:
  # a zpa_ header on them is ignored and they answer exactly as before.
  # Task 31 (D-Store leaf 7.a.vi.zo): `show` (GET /api/releases/:id) accepts the same two credentials --
  # it is the read a CI job polls to see whether the compile finished (`status`, `signed`,
  # `asset_delivery_state`, `asset_delivery_error`, all in Api::ReleaseStatusSerializer). update and
  # destroy keep the user-token rule they always had.
  before_action :validate_app_token, only: %i[release show], if: :app_token_presented?
  before_action :validate_user_token, unless: :app_token_request?
  before_action :set_release

  # GET /releases/:id
  def show
    render json: @release, serializer: Api::ReleaseStatusSerializer
  end

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

  # Task 40q: POST /api/releases/:id/retry_compile -- send a release to CI again (platform admin only).
  # The API twin of `CiCompileDispatchJob.enqueue_for(release)` from a Rails console, which a Render Free
  # service cannot offer (the Jobs API answers "new paid services not allowed", and the web Shell is a
  # browser path). It adds no behaviour of its own: `enqueue_for` still decides, so a release is only
  # re-sent when CI is on, it is an AAB and its state is NULL or `failed`; anything else is a 422 that
  # names the current state, and nothing changes. Never compiles, signs or touches a file here.
  #
  # @param id [Integer] required release id
  # @return [JSON] 202 with the new `ci_compile_state` (`queued`), or 422 with the current state and error
  def retry_compile
    if CiCompileDispatchJob.enqueue_for(@release)
      render json: { id: @release.id, ci_compile_state: @release.reload.ci_compile_state }, status: :accepted
    else
      @release.reload
      render json: { error: t('api.ci_compile_retry_refused', state: @release.ci_compile_state.inspect),
                     ci_compile_state: @release.ci_compile_state, ci_compile_error: @release.ci_compile_error },
             status: :unprocessable_entity
    end
  end

  # Task 44f: POST /api/releases/:id/rename_stored -- give the release's stored files today's names, in place
  # (platform admin only). A release stored before Task 44 keeps names like `pipeline__universal.apk`, which is
  # what a browser saves; this renames each stored file to `<app name>-<version><ext>` with the storage
  # adapter's own rename and records the new keys, so the release is never deleted or taken out of the index.
  # Safe to repeat. A release CI is still working on (`queued`, `dispatched`) is refused (422); a storage
  # failure is a 502 and names what GitHub said, and the keys of files not yet renamed stay as they were.
  #
  # @param id [Integer] required release id
  # @return [JSON] 200 with `changes` (column, from, to, status per file), or 422 / 502 with an error
  def rename_stored
    changes = ReleaseStoredRenamer.new(@release).call
    render json: { id: @release.id, changes: changes.map(&:to_h) }
  rescue ReleaseStoredRenamer::Refused => e
    render json: { error: t("api.rename_stored_refused.#{e.message}") }, status: :unprocessable_entity
  rescue ReleaseStorage::StorageError, ReleaseStorage::ConfigurationError => e
    render json: { error: t('api.rename_stored_storage_failed', reason: e.message) }, status: :bad_gateway
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
    # For every other action the query is nil, which lets Pundit infer the action's own predicate --
    # `update?`/`destroy?` as before, and, since Task 31, `show?` for the new read, which is true for
    # anyone (`ReleasePolicy#show?`); the per-app token confinement above already scopes it.
    authorize @release, (action_name == 'release' ? :update_status? : nil)
  end

  # True only for the actions that accept a `zpa_` bearer header (`release` and, since Task 31, `show`),
  # and only when such a header was actually presented; every other request keeps the user-token check.
  def app_token_request?
    %w[release show].include?(action_name) && app_token_presented?
  end

  def release_params
    params.permit(
      :release_version, :build_version, :release_type, :source, :branch, :git_commit,
      :ci_url, :custom_fields, :changelog
    )
  end
end
