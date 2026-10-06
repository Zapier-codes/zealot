# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TenantBuildLink do
  let(:secret) { 'test-link-secret' }
  let(:now) { 1_899_999_000 }

  # Known answer, so distr's signer can be checked against it:
  #   printf 'tenant-build-download\nb123\n1900000000' | openssl dgst -sha256 -hmac 'test-link-secret'
  it 'signs the documented message with HMAC-SHA256' do
    expect(described_class.sign('b123', 1_900_000_000, secret: secret)).to eq('44cc1c406d7309d5ad224f7c840562a78fe56af535217bcb177a6ad00e03508f')
  end

  it 'accepts a good signature before it expires' do
    sig = described_class.sign('b123', 1_900_000_000, secret: secret)
    expect(described_class.verify('b123', '1900000000', sig, now: now, secret: secret)).to eq(:ok)
  end

  it 'reports an expired link only after the signature checks out' do
    sig = described_class.sign('b123', 1_900_000_000, secret: secret)
    expect(described_class.verify('b123', '1900000000', sig, now: 1_900_000_001, secret: secret)).to eq(:expired)
    expect(described_class.verify('b123', '1900000000', '0' * 64, now: 1_900_000_001, secret: secret)).to eq(:invalid)
  end

  it 'is invalid for another build, a changed expiry, a blank value or a non-hex signature' do
    sig = described_class.sign('b123', 1_900_000_000, secret: secret)
    expect(described_class.verify('b124', '1900000000', sig, now: now, secret: secret)).to eq(:invalid)
    expect(described_class.verify('b123', '1900000001', sig, now: now, secret: secret)).to eq(:invalid)
    expect(described_class.verify('b123', nil, sig, now: now, secret: secret)).to eq(:invalid)
    expect(described_class.verify('b123', '1900000000', sig.upcase, now: now, secret: secret)).to eq(:invalid)
  end

  it 'refuses an expiry further out than MAX_TTL even when genuinely signed' do
    far = now + described_class::MAX_TTL + 1
    sig = described_class.sign('b123', far, secret: secret)
    expect(described_class.verify('b123', far.to_s, sig, now: now, secret: secret)).to eq(:invalid)
  end

  it 'is :unconfigured without a secret' do
    expect(described_class.verify('b123', '1900000000', 'a' * 64, now: now, secret: '')).to eq(:unconfigured)
  end
end
