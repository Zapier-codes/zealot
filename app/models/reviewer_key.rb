# frozen_string_literal: true

# Z-P9 (principle 2): the device-bound pseudonymous review key. The phone makes an EC key in the Android
# Keystore and presents the certificate chain; the SHA-256 of the public key is the pseudonym. The key is
# never an account -- it has no email, no profile, and a review is accepted without one. It exists only so
# that (a) one device has one editable review per app and (b) a review that arrived with proof the reviewed
# version was installed can carry the "verified install" mark.
#
# A key is looked up by `fingerprint`, which is unique per tenant (the same physical key on two tenants'
# hosts is two rows -- nothing about one tenant's reviewers is visible to another).
class ReviewerKey < ApplicationRecord
  include TenantOwned

  has_many :anonymous_reviews, dependent: :destroy

  validates :fingerprint, presence: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :attestation_status, inclusion: { in: %w[unverified verified failed unsupported] }

  scope :verified, -> { where(attestation_verified: true) }
  scope :recent, -> { order(last_seen_at: :desc, id: :desc) }

  # `fingerprint` from a raw public key. The phone hashes the SPKI bytes; the same bytes arrive here as a PEM, so
  # the writer hashes the DER it encodes. Accepts any key type the Keystore can make (EC is the current client's
  # choice; RSA is still valid), so the fingerprint is the hash of whatever SPKI was presented. Centralised so
  # the client and this model cannot disagree on the spelling.
  def self.fingerprint_for(public_key_pem)
    der = OpenSSL::PKey.read(public_key_pem).public_to_der
    OpenSSL::Digest::SHA256.hexdigest(der)
  end

  # Touch on every use so a key that stops appearing can be aged out later; cheap, and keeps `recent` useful.
  def touch_seen!
    update_column(:last_seen_at, Time.current)
  end

  # Record the outcome of an Android Key Attestation check. `verified` requires a real chain; anything else is
  # recorded as-is and never silently upgraded to verified.
  def record_attestation!(status:, verified:)
    update!(attestation_status: status.to_s, attestation_verified: !!verified,
            attestation_verified_at: (verified ? Time.current : nil))
  end
end
