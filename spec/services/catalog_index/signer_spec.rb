# frozen_string_literal: true

require 'rails_helper'

# Task 27b-ii. See app/services/catalog_index/signer.rb. The pure timestamp
# rule and the sign/verify round trip were also run for real in plain Ruby.
RSpec.describe CatalogIndex::Signer do
  describe '.next_generated_at' do
    let(:now) { Time.utc(2026, 9, 27, 12, 0, 30, 400_000) }

    it 'is now, truncated to the second, when nothing was signed before' do
      expect(described_class.next_generated_at(now, nil)).to eq(Time.utc(2026, 9, 27, 12, 0, 30))
    end

    it 'is at least one second after the previous signing, even if the clock went back' do
      last = Time.utc(2026, 9, 27, 13, 0, 0)

      expect(described_class.next_generated_at(now, last)).to eq(Time.utc(2026, 9, 27, 13, 0, 1))
    end
  end

  describe '.call' do
    it 'raises a clear error when no signing key exists' do
      expect { described_class.call([], key: nil) }.to raise_error(described_class::NoKeyError, /generate_key/)
    end

    it 'signs the exact bytes, advances the persisted time, and never repeats a timestamp' do
      key = CatalogIndexSigningKey.generate!
      now = Time.utc(2026, 9, 27, 12, 0, 0)

      first = described_class.call([], now: now, key: key)
      second = described_class.call([], now: now, key: key)

      expect(CatalogIndex::Ed25519.verify(key.public_key, first.index_json, first.signature)).to be true
      expect(second.generated_at).to be > first.generated_at
      expect(key.reload.last_signed_at).to eq(second.generated_at)
    end

    it 'leaves draft and archived apps out of the default catalog' do
      live = create(:app, listing_status: :live)
      create(:app, listing_status: :draft)
      create(:app, listing_status: :live, archived: true)
      key = CatalogIndexSigningKey.generate!

      result = described_class.call(nil, key: key)

      expect(JSON.parse(result.index_json)['apps'].map { |a| a['id'] }).to eq([live.id])
    end
  end
end
