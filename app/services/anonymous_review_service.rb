# frozen_string_literal: true

# Z-P9 (principle 2): write one anonymous review. This is the whole gate between "anyone can post" and "the
# storefront stays readable", and it is deliberately linear so the order is auditable:
#
#   1. the proof-of-work challenge must be solved and unused (AnonymousReview / ReviewChallenge);
#   2. the per-key and per-network rate limits must allow it (AnonymousReviewRateLimit);
#   3. the device key, if one is given, must be the key it claims (signature over the payload);
#   4. the automated moderator decides publish / pending / reject (AnonymousReviewModerator);
#   5. the "verified install" mark is set only when the key is attestation-verified and the reviewed
#      `version_code` is a release of this app -- proof the reviewed build was actually installed.
#
# On success the review is upserted on (app, reviewer_key), so a person has one editable review per app.
# A review with no key (the website path) is a new anonymous row each time -- there is no key to edit by,
# which is the honest consequence of "no accounts".
#
# The service never raises for bad input; it returns a Result with a `reason`, and the controller turns the
# reason into the right status (422 for a bad solution, 429 for a rate limit).
class AnonymousReviewService
  Result = Struct.new(:review, :decision, :reason, :retry_after, keyword_init: true) do
    def ok? = review.present?
  end

  def initialize(remote_ip: nil, moderator: AnonymousReviewModerator.new, rate_limit: AnonymousReviewRateLimit.new)
    @remote_ip = remote_ip
    @moderator = moderator
    @rate_limit = rate_limit
  end

  # Fields: `app`, `package_name` (the URL segment the client addressed, signed over), `rating`, `body`,
  # `challenge` (raw nonce), `solution` (the solved number), `reviewer_key_fingerprint` + `signature`
  # (optional, the client path), `version_code` (optional).
  def submit!(app:, package_name:, rating:, body:, challenge:, solution:, reviewer_key_fingerprint: nil,
              signature: nil, version_code: nil, tenant: nil)
    challenge_record = ReviewChallenge.where(nonce: challenge.to_s).first
    return fail(:unknown_challenge) if challenge_record.nil?
    return fail(:expired_challenge) if challenge_record.expired? || challenge_record.solved_at.present?
    return fail(:bad_solution) unless challenge_record.solution_valid?(solution)

    key = resolve_key(reviewer_key_fingerprint, tenant: tenant)
    return fail(:unknown_key) if reviewer_key_fingerprint.present? && key.nil?

    if key && !signature_valid?(key, package_name: package_name, rating: rating, body: body,
                                version_code: version_code, challenge: challenge_record.nonce,
                                signature: signature)
      return fail(:bad_signature)
    end

    key_limit = @rate_limit.key_allowed?(reviewer_key: key)
    return Result.new(decision: :refused, reason: key_limit.reason, retry_after: key_limit.retry_after) unless key_limit.allowed?

    # Consume the challenge only after every cheap check has passed, so a refused submission does not burn it
    # unless it was otherwise valid (and a genuinely bad solution is caught above, before consumption).
    return fail(:challenge_used) unless challenge_record.consume!

    decision = @moderator.moderate(rating: rating, body: body)
    review = upsert(app: app, key: key, rating: rating, body: body, version_code: version_code,
                    decision: decision, tenant: tenant)
    Result.new(review: review, decision: decision.decision, reason: decision.reason)
  end

  # Issue a challenge, applying the network limit first. Returns a Result carrying the challenge (or the
  # refusal); the controller serializes it.
  def issue_challenge!(tenant: nil)
    digest = ReviewChallenge.ip_digest_for(@remote_ip)
    limit = @rate_limit.challenge_allowed?(ip_digest: digest)
    return Result.new(decision: :refused, reason: limit.reason, retry_after: limit.retry_after) unless limit.allowed?

    Result.new(review: ReviewChallenge.issue!(remote_ip: @remote_ip, tenant: tenant))
  end

  private

  def fail(reason)
    Result.new(decision: :refused, reason: reason)
  end

  def resolve_key(fingerprint, tenant:)
    return nil if fingerprint.blank?

    ReviewerKey.for_tenant(tenant).find_by(fingerprint: fingerprint.to_s.downcase)
  end

  # The canonical bytes a client signs. Public and stable, so the Android client and this method can never
  # drift: version tag, the package name the client addressed, rating, a digest of the body (the body can be
  # long and must not be re-encoded differently), the version code, and the challenge nonce (binds the
  # signature to this submission). The client names the app by package, not by id, so package is what is signed.
  def self.signed_payload(package_name:, rating:, body:, version_code:, challenge:)
    body_digest = OpenSSL::Digest::SHA256.hexdigest(body.to_s)
    ['ZP9v1', package_name.to_s, rating.to_s, body_digest, version_code.to_s, challenge.to_s].join("\n")
  end

  def signature_valid?(key, package_name:, rating:, body:, version_code:, challenge:, signature:)
    return false if signature.blank? || key.public_key_pem.blank?

    payload = self.class.signed_payload(package_name: package_name, rating: rating, body: body,
                                        version_code: version_code, challenge: challenge)
    pkey = OpenSSL::PKey.read(key.public_key_pem)
    pkey.verify(OpenSSL::Digest::SHA256.new, Base64.decode64(signature.to_s), payload)
  rescue OpenSSL::PKey::PKeyError, OpenSSL::PKey::RSAError, ArgumentError
    false
  end

  def upsert(app:, key:, rating:, body:, version_code:, decision:, tenant:)
    attrs = {
      rating: rating.to_i,
      body: body.to_s.strip.presence,
      status: status_for(decision.decision),
      moderation_reason: decision.reason,
      version_code: version_code.to_s.presence,
      verified_install: verified_install?(key: key, app: app, version_code: version_code),
      tenant: tenant,
    }

    if key
      review = app.anonymous_reviews.find_or_initialize_by(reviewer_key: key)
      review.assign_attributes(attrs)
      review.save!
      review
    else
      app.anonymous_reviews.create!(attrs.merge(reviewer_key: anonymous_key(tenant: tenant)))
    end
  end

  # A review with no device key still needs a `reviewer_key` row (the column is non-null), so it gets a
  # synthetic per-review key with a random fingerprint that is never registered and never reused -- it cannot
  # edit and never carries the install mark. Kept out of the registered set by construction (random 32 bytes).
  def anonymous_key(tenant:)
    ReviewerKey.create!(fingerprint: SecureRandom.hex(32), attestation_status: 'unsupported', tenant: tenant)
  end

  def status_for(decision)
    case decision
    when :reject then 'rejected'
    when :pending then 'pending'
    else 'published'
    end
  end

  # The mark is proof the reviewed build was installed: the key must be attestation-verified (a real device),
  # and the reviewed version code must be one of the app's releases. Both are required; either alone is not
  # enough, and neither is guessed. Release versions are integers, so the client's string code is coerced once.
  def verified_install?(key:, app:, version_code:)
    return false if key.nil? || !key.attestation_verified?
    return false if version_code.blank?

    app.play_releases_scope.where(version: version_code.to_i).exists?
  rescue NoMethodError
    false
  end
end
