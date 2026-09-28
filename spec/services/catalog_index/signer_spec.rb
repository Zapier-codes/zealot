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

    # Task 37b-ii-k4: the default tenant's output must not move.
    it 'signs the default tenant exactly as before when the key comes from the resolver (golden)' do
      key = CatalogIndexSigningKey.generate!
      now = Time.utc(2026, 9, 27, 12, 0, 0)

      explicit = described_class.call([], now: now, key: key)
      key.update_columns(last_signed_at: nil)
      via_resolver = described_class.call([], now: now)
      key.update_columns(last_signed_at: nil)
      via_default_tenant = described_class.call([], now: now, tenant: 'default')

      [via_resolver, via_default_tenant].each do |result|
        expect(result.index_json).to eq(explicit.index_json)
        expect(result.signature).to eq(explicit.signature)
        expect(result.key_id).to eq(explicit.key_id)
        expect(result.generated_at).to eq(explicit.generated_at)
      end
      expect(explicit.signatures).to eq([{ key_id: key.key_id, signature: explicit.signature }])
    end

    it 'signs a tenant with its own key, never the default one' do
      default_key = CatalogIndexSigningKey.generate!
      tenant_key = create(:tenant_signing_key, tenant: create(:tenant, tenant_id: 'acme'))

      result = described_class.call([], now: Time.utc(2026, 9, 27), tenant: 'acme')

      expect(result.key_id).to eq(tenant_key.key_id)
      expect(CatalogIndex::Ed25519.verify(tenant_key.public_key, result.index_json, result.signature)).to be true
      expect(CatalogIndex::Ed25519.verify(default_key.public_key, result.index_json, result.signature)).to be false
    end

    # Task 37b-iii-s3: `default_apps` (what the default tenant's index is built from when no apps are
    # passed) must not include an app a tenant owns.
    it 'builds the default tenant\'s index from apps with no tenant only' do
      CatalogIndexSigningKey.generate!
      default_app = create(:app, listing_status: :live, listed_at: Time.current)
      create(:app, listing_status: :live, listed_at: Time.current, tenant: create(:tenant, tenant_id: 'acme'))

      result = described_class.call(now: Time.utc(2026, 9, 30, 12))

      expect(JSON.parse(result.index_json)['apps'].map { |a| a['id'] }).to eq([ default_app.id ])
    end

    # Task 37b-iii-s4 (replaces the k4 example that made a tenant pass its apps explicitly).
    it 'signs a non-default tenant over its own apps only when none are passed' do
      acme = create(:tenant, tenant_id: 'acme')
      create(:tenant_signing_key, tenant: acme)
      default_app = create(:app, listing_status: :live, listed_at: Time.current)
      acme_app = create(:app, listing_status: :live, listed_at: Time.current, tenant: acme)
      create(:app, listing_status: :live, listed_at: Time.current, tenant: create(:tenant, tenant_id: 'globex'))

      result = described_class.call(nil, now: Time.utc(2026, 9, 30, 12), tenant: 'acme')

      ids = JSON.parse(result.index_json)['apps'].map { |a| a['id'] }
      expect(ids).to eq([ acme_app.id ])
      expect(ids).not_to include(default_app.id)
    end

    it 'signs a tenant with no apps as an empty index, not the default catalog' do
      create(:tenant_signing_key, tenant: create(:tenant, tenant_id: 'acme'))
      create(:app, listing_status: :live, listed_at: Time.current)

      result = described_class.call(nil, now: Time.utc(2026, 9, 30, 12), tenant: 'acme')

      expect(JSON.parse(result.index_json)['apps']).to eq([])
    end

    it 'raises, naming the tenant, for a tenant without a key' do
      create(:tenant, tenant_id: 'acme')

      expect { described_class.call([], tenant: 'acme') }.to raise_error(CatalogIndex::Signer::NoKeyError, /acme/)
    end

    describe 'during a key rotation overlap (k5)' do
      let(:tenant) { create(:tenant, tenant_id: 'acme') }
      let(:lifecycle) { TenantKeys::Lifecycle.new(tenant) }
      let(:now) { Time.utc(2026, 9, 27, 12, 0, 0) }

      before do
        @old = lifecycle.generate!
        lifecycle.stage_next!
        @new = lifecycle.promote!
      end

      it 'verifies the same bytes under EACH key, with the active key as the primary' do
        result = described_class.call([], now: now, tenant: 'acme')

        expect(result.signatures.map { |s| s[:key_id] }).to eq([@new.key_id, @old.key_id])
        expect(result.key_id).to eq(@new.key_id)
        expect(result.signature).to eq(result.signatures.first[:signature])
        [@new, @old].each do |key|
          signature = result.signatures.find { |s| s[:key_id] == key.key_id }[:signature]
          expect(CatalogIndex::Ed25519.verify(key.public_key, result.index_json, signature)).to be true
        end
      end

      it 'uses the maximum counter and advances every key to it; neither goes backwards' do
        @old.update_columns(last_signed_at: Time.utc(2026, 9, 27, 13, 0, 0))
        @new.update_columns(last_signed_at: Time.utc(2026, 9, 27, 11, 0, 0))

        result = described_class.call([], now: now, tenant: 'acme')

        expect(result.generated_at).to eq(Time.utc(2026, 9, 27, 13, 0, 1))
        expect(@old.reload.last_signed_at).to eq(result.generated_at)
        expect(@new.reload.last_signed_at).to eq(result.generated_at)
      end

      it 'never repeats a timestamp across calls' do
        first = described_class.call([], now: now, tenant: 'acme')
        second = described_class.call([], now: now, tenant: 'acme')

        expect(second.generated_at).to be > first.generated_at
      end

      it 'locks the key rows in ascending id order' do
        locked = []
        callback = lambda do |*, payload|
          next unless payload[:sql].include?('FOR UPDATE') && payload[:sql].include?('tenant_signing_keys')

          locked << payload[:binds].map(&:value).first
        end
        ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
          described_class.call([], now: now, tenant: 'acme')
        end

        expect(locked.first(2)).to eq([@old.id, @new.id].sort)
      end

      it 'rolls every counter back if signing fails part-way' do
        allow_any_instance_of(TenantSigningKey).to receive(:sign).and_wrap_original do |orig, *args|
          raise 'boom' if orig.receiver.id == @old.id

          orig.call(*args)
        end
        before = [@old, @new].map { |k| k.reload.last_signed_at }

        expect { described_class.call([], now: now, tenant: 'acme') }.to raise_error('boom')
        expect([@old, @new].map { |k| k.reload.last_signed_at }).to eq(before)
      end

      it 'is unchanged for a one-key tenant once the old key is retired' do
        lifecycle.retire!(force: true)
        result = described_class.call([], now: now, tenant: 'acme')

        expect(result.signatures.size).to eq(1)
        expect(result.key_id).to eq(@new.key_id)
      end
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
