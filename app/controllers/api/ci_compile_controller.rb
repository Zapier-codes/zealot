# frozen_string_literal: true

# Task 40a: the one door through which the storage repo's compile workflow (Task 40) reports back.
# Zealot no longer compiles, splits, signs or compresses a release itself; CI does, uploads what it
# built to the release's storage tag, and calls this endpoint once with a small JSON body.
#
# Authentication is a shared secret only (`CI_COMPILE_CALLBACK_TOKEN`, sent as
# `Authorization: Bearer <token>`). It is deliberately not a user token or a per-app token: the caller
# is a workflow, not a person. If the variable is unset, every call is refused (the endpoint is never
# open by default). The decided Task 40 flow later moves the callbacks to GitHub OIDC (slice 40i-a);
# this token is the 40a stand-in and is replaced there, not extended.
#
# Verification before `done`: both files CI claims to have uploaded must exist in storage, and, when
# `CI_COMPILE_EXPECT_CERT_SHA256` is set, the signing certificate CI reports must equal it. A body that
# fails either check marks the release `failed` with the reason (a misconfigured CI shows up as
# `failed`, not as a release stuck in `dispatched`). A malformed body (missing field, bad hash) is
# refused with 422 and changes nothing, so CI can send it again.
#
# Idempotent: the same `done` body for a release already `done` answers 200 and writes nothing. A
# callback for a release that is not `queued` or `dispatched` is refused with 409.
class Api::CiCompileController < Api::BaseController
  OPEN_STATES = %w[queued dispatched].freeze
  SHA256_FORMAT = /\A[0-9a-f]{64}\z/
  PERMITTED = %i[
    state error universal_apk_key universal_apk_sha256 universal_apk_size
    compressed_apks_key compressed_size cert_sha256
  ].freeze

  before_action :authenticate_callback!

  # POST /api/ci_compile/:id/callback
  #
  #   { "state": "done", "universal_apk_key": "...", "universal_apk_sha256": "<64 hex>",
  #     "universal_apk_size": 123, "compressed_apks_key": "...", "compressed_size": 45,
  #     "cert_sha256": "<64 hex, optional unless the expectation is configured>" }
  #   { "state": "failed", "error": "why" }
  def callback
    release = Release.find(params[:id])
    body = params.permit(*PERMITTED)

    case body[:state]
    when 'done' then finish_done(release, body)
    when 'failed' then finish_failed(release, body)
    else render json: { error: "state must be 'done' or 'failed'" }, status: :unprocessable_entity
    end
  end

  private

  def authenticate_callback!
    expected = ENV['CI_COMPILE_CALLBACK_TOKEN'].to_s
    supplied = request.authorization.to_s.sub(/\ABearer\s+/i, '')
    return if expected.present? && supplied.present? && same_secret?(expected, supplied)

    render json: { error: 'Unauthorized' }, status: :unauthorized
  end

  # Compares digests, so the comparison is constant-time whatever the lengths are.
  def same_secret?(left, right)
    ActiveSupport::SecurityUtils.secure_compare(
      ::Digest::SHA256.hexdigest(left), ::Digest::SHA256.hexdigest(right)
    )
  end

  def finish_failed(release, body)
    return refuse_state(release) unless OPEN_STATES.include?(release.ci_compile_state)

    record_failure(release, body[:error].presence || 'CI reported a failure without a reason')
    render json: { message: 'OK' }, status: :ok
  end

  def finish_done(release, body)
    sha = body[:universal_apk_sha256].to_s.downcase
    # A repeat of the call that already succeeded is answered the same way and writes nothing.
    return render(json: { message: 'OK' }, status: :ok) if repeat_of_done?(release, sha)
    return refuse_state(release) unless OPEN_STATES.include?(release.ci_compile_state)

    problem = malformed(body, sha)
    return render(json: { error: problem }, status: :unprocessable_entity) if problem

    reason = verification_failure(release, body)
    return reject_result(release, reason) if reason

    save_done(release, body, sha)
    queue_local_eviction(release)
    render json: { message: 'OK' }, status: :ok
  end

  def repeat_of_done?(release, sha)
    release.ci_compile_done? && sha.present? && release.universal_apk_sha256 == sha
  end

  def refuse_state(release)
    state = release.ci_compile_state.inspect
    render json: { error: "release is not waiting for a CI result (ci_compile_state: #{state})" },
           status: :conflict
  end

  # @return [String, nil] what is wrong with the body's shape, or nil
  def malformed(body, sha)
    missing = %i[universal_apk_key compressed_apks_key].select { |key| body[key].blank? }
    return "missing: #{missing.join(', ')}" if missing.any?
    return 'universal_apk_sha256 must be 64 hex characters' unless SHA256_FORMAT.match?(sha)
    return 'universal_apk_size must be a positive integer' unless positive_integer?(body[:universal_apk_size])
    return 'compressed_size must be a positive integer' if body[:compressed_size].present? &&
                                                          !positive_integer?(body[:compressed_size])
    return 'cert_sha256 is required' if expected_certificate.present? && body[:cert_sha256].blank?

    nil
  end

  def positive_integer?(value)
    Integer(value.to_s, 10).positive?
  rescue ArgumentError
    false
  end

  # @return [String, nil] why a well-formed result must not be trusted, or nil
  def verification_failure(release, body)
    if expected_certificate.present? && normalize_fingerprint(body[:cert_sha256]) != expected_certificate
      return 'the signing certificate CI reported does not match the expected certificate'
    end

    storage = ReleaseStorage.new(release)
    %i[universal_apk_key compressed_apks_key].each do |field|
      return "#{body[field]} is not in storage" unless storage.exist?(body[field])
    end

    nil
  end

  def expected_certificate
    normalize_fingerprint(ENV['CI_COMPILE_EXPECT_CERT_SHA256'])
  end

  # Accepts `AA:BB:..` (keytool's form) or bare hex, in either case.
  def normalize_fingerprint(value)
    value.to_s.delete(':').strip.downcase
  end

  def reject_result(release, reason)
    record_failure(release, reason)
    render json: { error: reason }, status: :unprocessable_entity
  end

  def record_failure(release, reason)
    release.update!(ci_compile_state: 'failed', ci_compile_error: reason.to_s.truncate(1000),
                    ci_compile_finished_at: Time.current)
    # Task 30: the CI path is the compile; mirror its outcome into asset_delivery_state so a reader polls
    # one field whatever compiled the bundle.
    release.record_asset_delivery!(:failed, error: reason)
  end

  def save_done(release, body, sha)
    attributes = {
      ci_compile_state: 'done', ci_compile_error: nil, ci_compile_finished_at: Time.current,
      universal_apk_storage_key: body[:universal_apk_key], universal_apk_sha256: sha,
      universal_apk_size: Integer(body[:universal_apk_size].to_s, 10),
      compressed_apks_storage_key: body[:compressed_apks_key], brotli_compressed: true
    }
    attributes[:compressed_size] = Integer(body[:compressed_size].to_s, 10) if body[:compressed_size].present?
    release.update!(attributes)
    # Task 30: CI finished the compile; record the same outcome the Ruby path records.
    release.record_asset_delivery!(:done)
  end

  # Task 40f: the bundle on local disk is no longer needed once the result is recorded; the job re-checks
  # everything itself before deleting. Housekeeping only: a queue problem must not turn CI's accepted result
  # into an error (the result is already saved, and `ReleaseLocalEvictionJob.backfill` catches up later).
  def queue_local_eviction(release)
    ReleaseLocalEvictionJob.perform_later(release.id)
  rescue StandardError => e
    Rails.logger.error("[Api::CiCompileController] release #{release.id}: could not queue local eviction: #{e.message}")
  end
end
