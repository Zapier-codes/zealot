# frozen_string_literal: true

require 'rails_helper'

# Task 27b-ii. Same checks were run for real (plain Ruby, plus an independent
# verification in Node crypto/WebCrypto) while building this slice.
RSpec.describe CatalogIndex::Ed25519 do
  let(:pem) { described_class.generate_pem }
  let(:pub) { described_class.public_key_b64(pem) }

  it 'exposes the public key as base64 of the raw 32 bytes' do
    expect(Base64.strict_decode64(pub).bytesize).to eq(32)
  end

  it 'gives a short, stable, non-secret key id' do
    expect(described_class.key_id(pub)).to match(/\A\h{16}\z/)
    expect(described_class.key_id(pub)).to eq(described_class.key_id(pub))
  end

  it 'verifies a signature over exactly the signed bytes' do
    sig = described_class.sign(pem, 'index bytes')

    expect(described_class.verify(pub, 'index bytes', sig)).to be true
    expect(described_class.verify(pub, 'index bytez', sig)).to be false
    expect(described_class.verify(described_class.public_key_b64(described_class.generate_pem), 'index bytes', sig)).to be false
  end

  it 'returns false, never raises, on malformed input' do
    expect(described_class.verify(pub, 'x', 'not base64!!')).to be false
    expect(described_class.verify('AAAA', 'x', described_class.sign(pem, 'x'))).to be false
  end
end
