# frozen_string_literal: true

require 'base64'

# Z-P19: the Standard Webhooks signature scheme, the same shape Svix uses, so a receiver can verify a
# delivery with the libraries already written for that format. The signed content is
#
#   <webhook-id>.<webhook-timestamp>.<body>
#
# and the header is
#
#   webhook-signature: v1,<base64(HMAC-SHA256(secret, signed_content))>
#
# The secret is the Standard Webhooks format `whsec_<base64>`; the bytes HMAC'd are the part after `whsec_`.
# A web hook with no secret on file is not signed (nil), and its deliveries stay byte-for-byte as they were.
module Webhooks
  class StandardSignature
    SCHEME = 'v1'
    PREFIX = 'whsec_'
    # Default tolerance for a receiver's own replay check; exposed so a caller can state it consistently.
    TOLERANCE_SECONDS = 5 * 60

    class << self
      # @return [String, nil] the `webhook-signature` header value, or nil when there is no secret to sign with
      def header(secret:, webhook_id:, timestamp:, body:)
        return nil if secret.blank?

        digest = OpenSSL::HMAC.digest('sha256', signing_key(secret), signed_content(webhook_id, timestamp, body))
        "#{SCHEME},#{Base64.strict_encode64(digest)}"
      end

      # Verifies a delivery the way a receiver would. Returns true only for a well-formed, unexpired,
      # correctly-signed payload. Kept here (not only in the receiver) so a spec can prove the pair.
      def valid?(secret:, webhook_id:, timestamp:, body:, signature:, now: Time.current, tolerance: TOLERANCE_SECONDS)
        return false if secret.blank? || signature.blank? || webhook_id.blank? || timestamp.blank?
        return false if timestamp.to_i.positive? && (now.to_i - timestamp.to_i).abs > tolerance

        expected = header(secret: secret, webhook_id: webhook_id, timestamp: timestamp, body: body)
        return false if expected.nil?

        # The header may carry several space-separated signatures (e.g. during rotation); any one match is enough.
        signature.to_s.split(' ').any? { |candidate| secure_compare(candidate, expected) }
      end

      private

      def signed_content(webhook_id, timestamp, body)
        "#{webhook_id}.#{timestamp}.#{body}"
      end

      # Standard Webhooks secrets are `whsec_<base64>`; HMAC with the decoded bytes. A secret that is not in
      # that form is used as raw bytes, so a plain shared string still works.
      def signing_key(secret)
        return Base64.strict_decode64(secret.delete_prefix(PREFIX)) if secret.start_with?(PREFIX)

        secret
      rescue ArgumentError
        secret
      end

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        OpenSSL.fixed_length_secure_compare(a, b)
      end
    end
  end
end
