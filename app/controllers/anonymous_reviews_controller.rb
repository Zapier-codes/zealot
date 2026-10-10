# frozen_string_literal: true

# Z-P9 (principle 2): the anonymous review API. Public and session-less -- there is no sign-in, no email and
# no profile anywhere in this path. Three routes, one per step:
#
#   GET  /reviews/:package_name/challenge   issue a proof-of-work challenge (ALTCHA shape)
#   POST /reviews/:package_name/keys        register a device-bound key (attestation checked here)
#   POST /reviews/:package_name             submit the solved, optionally-signed review
#
# The package name identifies the app (the same `play_package_name` a client knows); an unknown package is a
# 404, never a silent no-op. The challenge step is the only unauthenticated write, and it is bounded per
# network without ever storing the address.
class AnonymousReviewsController < ActionController::API
  before_action :set_app

  # GET /reviews/:package_name/challenge
  def challenge
    result = service.issue_challenge!(tenant: current_tenant)
    return render_refusal(result) unless result.ok?

    challenge = result.review
    render json: { nonce: challenge.nonce, salt: challenge.salt, cost: challenge.cost,
                   algorithm: 'SHA-256(salt+number+nonce) has cost leading zero hex nibbles',
                   expires_in: ReviewChallenge::TTL.to_i }
  end

  # POST /reviews/:package_name/keys
  # Body: public_key (PEM), attestation_chain[] (leaf..root PEM), challenge (the nonce this key was made
  # with), signature (proves possession of the private key over the registration payload).
  def register_key
    public_key = params[:public_key].to_s
    return render json: { error: 'public_key_required' }, status: :unprocessable_entity if public_key.blank?

    fingerprint = ReviewerKey.fingerprint_for(public_key)
    result = AndroidKeyAttestation.new.verify(
      chain_pems: Array(params[:attestation_chain]),
      challenge: params[:challenge].to_s,
      public_key_der: OpenSSL::PKey.read(public_key).public_to_der
    )

    key = ReviewerKey.for_tenant(current_tenant).find_or_initialize_by(fingerprint: fingerprint)
    key.public_key_pem = public_key
    key.record_attestation!(status: result.status, verified: result.verified)
    key.last_seen_at = Time.current
    key.tenant = current_tenant
    key.save!

    render json: { fingerprint: fingerprint, attestation_status: result.status,
                   verified: result.verified, security_level: result.security_level,
                   reason: result.reason }, status: :created
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::RSAError
    render json: { error: 'invalid_public_key' }, status: :unprocessable_entity
  end

  # POST /reviews/:package_name
  # Body: rating, body, challenge (nonce), solution, and optionally reviewer_key_fingerprint + signature +
  # version_code. The device key is what allows the review to be edited later and to carry the install mark.
  def create
    result = service.submit!(
      app: @app,
      package_name: params[:package_name],
      rating: params[:rating],
      body: params[:body],
      challenge: params[:challenge],
      solution: params[:solution],
      reviewer_key_fingerprint: params[:reviewer_key_fingerprint],
      signature: params[:signature],
      version_code: params[:version_code],
      tenant: current_tenant
    )
    return render_refusal(result) unless result.ok?

    review = result.review
    render json: { review: serialize(review), decision: result.decision }, status: :created
  end

  private

  def service
    @service ||= AnonymousReviewService.new(remote_ip: request.remote_ip)
  end

  # Which app: the package name a client uses. A `play_package_name` match first, then the newest release's
  # `bundle_id` (an app that has not been migrated to Play naming still answers). Unknown -> 404.
  def set_app
    package = params[:package_name].to_s
    @app = App.for_tenant(current_tenant).find_by(play_package_name: package)
    @app ||= App.for_tenant(current_tenant).joins(:releases).where(releases: { bundle_id: package }).first
    render json: { error: 'app_not_found' }, status: :not_found if @app.nil?
  end

  def current_tenant
    Current.tenant
  rescue NoMethodError
    nil
  end

  def render_refusal(result)
    status = result.reason.to_s.include?('rate_limited') ? :too_many_requests : :unprocessable_entity
    headers['Retry-After'] = result.retry_after.to_i.to_s if result.retry_after
    render json: { error: result.reason, retry_after: result.retry_after }, status: status
  end

  def serialize(review)
    { id: review.id, rating: review.rating, body: review.body, status: review.status,
       verified_install: review.marked_verified?, version_code: review.version_code,
       created_at: review.created_at.iso8601 }
  end
end
