# frozen_string_literal: true

# Task 40n-f (door auth): signs and verifies the expiring links distr puts behind the email button.
#
# A link is the door URL plus two query parameters:
#
#   /api/tenant_builds/<build_id>/download?expires=<unix seconds>&signature=<64 hex>
#
# signature = HMAC-SHA256(DISTR_LINK_SECRET, "tenant-build-download\n<build_id>\n<expires>"), lowercase hex.
# distr signs with any HMAC library (the runbook has an `openssl` one-liner that produces the same bytes).
# The secret never leaves the two servers; a browser clicking the link needs no header, no account and no session.
#
# Checks, in this order, all failing closed:
#   1. the secret is configured (otherwise :unconfigured, so a missing variable is not mistaken for a bad link);
#   2. both parameters are present and well formed;
#   3. the signature matches, compared in constant time;
#   4. the link has not expired;
#   5. the expiry is no further away than MAX_TTL, so a link signed with a far-future date is refused even if the
#      signature is genuine (limits what a leaked or careless signer can hand out).
# The signature is checked before the expiry is looked at, so an unsigned caller learns nothing about timing.
class TenantBuildLink
  CONTEXT = 'tenant-build-download'
  MAX_TTL = 7 * 24 * 60 * 60 # seconds
  SIGNATURE_FORMAT = /\A[0-9a-f]{64}\z/
  EXPIRES_FORMAT = /\A\d{1,12}\z/

  # Returns :ok, :unconfigured, :invalid or :expired.
  def self.verify(build_id, expires, signature, now: Time.now.to_i, secret: ENV['DISTR_LINK_SECRET'])
    return :unconfigured if secret.to_s.empty?

    expires = expires.to_s
    signature = signature.to_s
    return :invalid unless build_id.to_s.present? && EXPIRES_FORMAT.match?(expires) && SIGNATURE_FORMAT.match?(signature)

    expected = sign(build_id, expires, secret: secret)
    return :invalid unless ActiveSupport::SecurityUtils.secure_compare(expected, signature)

    expires_at = expires.to_i
    return :expired if expires_at <= now
    return :invalid if expires_at - now > MAX_TTL

    :ok
  end

  # The hex signature for a build id and an expiry (unix seconds, integer or string).
  def self.sign(build_id, expires, secret: ENV['DISTR_LINK_SECRET'])
    OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{CONTEXT}\n#{build_id}\n#{expires}")
  end
end
