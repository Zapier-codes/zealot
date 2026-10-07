# frozen_string_literal: true

# Task 31 (D-Store leaf 7.a.vi.zo): the release status a CI job polls -- `GET /api/releases/:id`. It carries
# only what a waiting workflow needs: which release it is, whether it is held or available, whether the
# bundle was signed, and how the compile went (`asset_delivery_state`, `asset_delivery_error`, Task 30).
#
# Read-only and additive: nothing here changes an existing answer. The same fields are added to
# Api::UploadAppSerializer, so the upload's own answer carries them too.
class Api::ReleaseStatusSerializer < ApplicationSerializer
  attributes :id, :version, :release_version, :build_version, :status, :signed,
             :asset_delivery_state, :asset_delivery_error, :ci_compile_state, :ci_compile_error,
             :app_id, :release_url, :created_at

  # `app_id` is the app's id, not the release's, so a CI job can address the listing routes
  # (`/api/apps/:app_id/...`) without a second lookup.
  def app_id
    object.app&.id
  end
end
