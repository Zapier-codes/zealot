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
#   200 { "upload_id": 1, "state": "processing", "stage": 1, "release_id": 7, "package_name": "...",
#         "storage_tag": "a3-r7" }
#
# This door builds no `Release` itself: a recorded report goes to `ReleaseUploadIntake`, which hands it to the one
# release builder (Task 40i-b). It fetches nothing from a URL beyond GitHub's published keys (inside the
# verifier) and writes no staging row. The answer for a good report carries `release_id` and `storage_tag`; a
# report the release checks refuse is answered 422 with `state: "failed"` and creates nothing. Idempotent: see
# `ReleaseUploadIntake`.
#
# Task 40i-c: the same workflow run reports a second time, after it has uploaded the files to the storage repo
# and (for a bundle) built the signed universal APK and the split set:
#
#   POST /api/release_uploads/:id/stage2
#     { "state": "ok", "file_key": "uploads/apps/a3/r7/binary/app.aab", "file_sha256": "<64 hex>",
#       "icon_key": "uploads/apps/a3/r7/icons/icon.png", "icon_sha256": "<64 hex>",
#       "universal_apk_key": "...", "universal_apk_sha256": "<64 hex>", "universal_apk_size": 123,
#       "compressed_apks_key": "...", "compressed_size": 45, "cert_sha256": "<64 hex>" }
#     { "state": "failed", "error": "why" }
#   200 { "upload_id": 1, "state": "done", "stage": 2, "release_id": 7, "status": "available" }
#
# It is authenticated by the same OIDC token and the same workflow file as stage 1 (both stages are jobs of
# `read-upload.yml`), and the release it finishes is the one stage 1 made: `ReleaseUploadFinisher` updates that
# release and creates none. See the finisher for the rules (state, idempotency, keys derived by Zealot, objects
# checked in storage before anything is recorded).
#
# Task 40n-c: for an uploaded APK the stage-2 report also says whether CI could read a valid signature inside it:
#
#     { ..., "apk_verified": true, "cert_sha256": "<64 hex, the one signer's certificate>" }
#     { ..., "apk_verified": false }
#
# CI only reports the fact; `ReleaseUploadFinisher` decides (REQUIRE_ORG_SIGNED_APKS) whether the APK is accepted.
#
# Task 40p: for either an APK or an AAB, the stage-2 report also says whether a scan of the file, run before any
# injection or signing step touched it, found a bandwidth-sharing/residential-proxy SDK already present:
#
#     { ..., "preexisting_bandwidth_sdk": true, "preexisting_bandwidth_sdk_names": ["Honeygain", "..."] }
#     { ..., "preexisting_bandwidth_sdk": false }
#
# CI only reports the fact (and, when true, which vendor name(s) matched, for the message the uploader sees);
# `ReleaseUploadFinisher` always rejects a `true` report -- there is no flag to turn this off, unlike
# `REQUIRE_ORG_SIGNED_APKS`, because the policy ("only the organisation's own CI may add this kind of SDK") does
# not depend on whether `SDK_INJECTION` happens to be on for this particular upload.
#
# Not verified: no Ruby in the sandbox this was written in; nothing was run.
class Api::ReleaseUploadCallbacksController < Api::BaseController
  PERMITTED = %i[
    state error kind package_name version_code version_name app_label min_sdk target_sdk file_sha256 file_size
    icon_key icon_sha256
  ].freeze

  # Task 40i-c: what the stage-2 report may carry. Everything else is dropped.
  STAGE2_PERMITTED = %i[
    state error file_key file_sha256 icon_key icon_sha256 universal_apk_key universal_apk_sha256
    universal_apk_size compressed_apks_key compressed_size cert_sha256 sdk_injected injected_file_sha256
    org_signed signed_file_sha256 apk_verified preexisting_bandwidth_sdk
  ].freeze

  before_action :authenticate_workflow!

  def stage1
    upload = ReleaseUpload.find(params[:id])
    body = params.permit(*PERMITTED, abis: []).to_h
    result = ReleaseUploadIntake.new(upload, body).call
    render json: result.payload, status: result.http
  end

  # Task 40i-c
  def stage2
    upload = ReleaseUpload.find(params[:id])
    body = params.permit(*STAGE2_PERMITTED, preexisting_bandwidth_sdk_names: []).to_h
    result = ReleaseUploadFinisher.new(upload, body).call
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
