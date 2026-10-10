# frozen_string_literal: true

FactoryBot.define do
  # Z-P9: a device-bound pseudonymous review key. Default is unverified (the honest state until an
  # attestation chain is checked); a spec that needs the install mark passes `attestation_verified: true`.
  factory :reviewer_key do
    fingerprint { SecureRandom.hex(32) }
    attestation_status { 'unverified' }
    attestation_verified { false }
  end
end
