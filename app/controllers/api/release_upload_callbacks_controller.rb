# frozen_string_literal: true

# Task 40i-a: the door through which the stage-1 workflow (`docs/ci/read-upload.yml`, in the storage repo)
# reports what it read from a staged upload. Authenticated by GitHub's OIDC ID token, never by a shared secret
# and never by a user or per-app token: the caller is a workflow, and `GithubOidcVerifier` checks its signature,
# audience, repository, event and workflow file. Until `CI_OIDC_AUDIENCE` (or `ZEALOT_DOMAIN`) is configured
# every call is refused. The token is checked before the upload is looked up, so an unauthenticated caller
# learns nothing about which ids exist.
#
#   POST /api/release_uploads/:id/stage1
#     { "state": "ok", "kind": "apk|aab", "package_name": "...", "version_code": 1, "version_name": "1.0",
#       "app_label": "...", "min_sdk": 21, "target_sdk": 34, "abis": ["arm64-v8a"], "file_sha256": "<64 hex>",
#       "file_size": 123, "icon_key": "staging/.../icon.png", "icon_sha256": "<64 hex>" }
#     { "state": "failed", "error": "why" }
#
# This door creates no `Release` (40i-b does), fetches nothing from a URL beyond GitHub's published keys (inside
# the verifier) and writes only the staging row. Idempotent: see `ReleaseUploadIntake`.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class Api::ReleaseUploadCallbacksController < Api::BaseController
  PERMITTED = %i[
    state error kind package_name version_code version_name app_label min_sdk target_sdk file_sha256 file_size
    icon_key icon_sha256
  ].freeze

  before_action :authenticate_workflow!

  def stage1
    upload = ReleaseUpload.find(params[:id])
    body = params.permit(*PERMITTED, abis: []).to_h
    result = ReleaseUploadIntake.new(upload, body).call
    render json: result.payload, status: result.http
  end

  private

  def authenticate_workflow!
    audience = oidc_audience
    return unauthorized('CI_OIDC_AUDIENCE is not configured') if audience.blank?

    token = request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]
    GithubOidcVerifier.new(audience: audience, repository: storage_repository,
                           workflow: ReleaseUploadDispatcher.workflow_name,
                           ref: ENV['CI_COMPILE_REF'].presence || CiCompileDispatcher::DEFAULT_REF).call(token)
  rescue GithubOidcVerifier::Invalid => e
    unauthorized(e.message)
  end

  # What the workflow asks GitHub to put in the token's `aud`: Zealot's own URL.
  def oidc_audience
    configured = ENV['CI_OIDC_AUDIENCE'].to_s.strip
    return configured if configured.present?

    domain = ENV['ZEALOT_DOMAIN'].to_s.strip
    domain.present? ? "https://#{domain}" : nil
  end

  def storage_repository
    ENV['CI_COMPILE_REPO'].presence || ENV['GITHUB_STORAGE_REPO'].to_s
  end

  # One generic answer; the reason is for the log only.
  def unauthorized(reason)
    logger.warn("[Api::ReleaseUploadCallbacksController] refused: #{reason}")
    render json: { error: 'Unauthorized' }, status: :unauthorized
  end
end
