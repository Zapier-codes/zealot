# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TenantKeys::Lifecycle do
  let(:tenant) { create(:tenant, tenant_id: 'acme') }
  let(:other_tenant) { create(:tenant, tenant_id: 'globex') }
  let(:t0) { Time.utc(2026, 10, 1, 12) }
  let(:now) { [t0] }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:lifecycle) { described_class.new(tenant, clock: -> { now.first }, logger: logger) }

  def statuses(t = tenant)
    TenantSigningKey.where(tenant: t).order(:id).pluck(:status)
  end

  def advance(duration)
    now[0] += duration
  end

  it 'refuses a tenant that is not a saved Tenant, and an unknown purpose' do
    expect { described_class.new(build(:tenant)) }.to raise_error(ArgumentError)
    expect { described_class.new('acme') }.to raise_error(ArgumentError)
    expect { described_class.new(tenant, purpose: 'tenant_config') }.to raise_error(ArgumentError)
  end

  describe '#generate!' do
    it 'creates the first key directly as active, sequence 1' do
      key = lifecycle.generate!

      expect(key).to be_active
      expect(key.sequence).to eq(1)
      expect(key.activated_at).to eq(t0)
      expect(TenantSigningKey.active_for(tenant)).to eq(key)
    end

    it 'is refused when the tenant already has a key, naming the tenant' do
      lifecycle.generate!

      expect { lifecycle.generate! }.to raise_error(described_class::InvalidState, /acme.*already has a key/)
      expect(statuses).to eq(['active'])
    end

    it 'gives each tenant its own key' do
      a = lifecycle.generate!
      b = described_class.new(other_tenant).generate!

      expect(a.public_key).not_to eq(b.public_key)
      expect(TenantSigningKey.active_for(tenant)).to eq(a)
    end
  end

  describe '#stage_next!' do
    it 'needs an active key first' do
      expect { lifecycle.stage_next! }.to raise_error(described_class::InvalidState, /acme.*no active key/)
    end

    it 'creates one pending key that cannot sign, and refuses a second' do
      lifecycle.generate!
      pending = lifecycle.stage_next!

      expect(pending).to be_pending
      expect(pending.sequence).to eq(2)
      expect { pending.sign('x') }.to raise_error(TenantSigningKey::NotSigningError)
      expect { lifecycle.stage_next! }.to raise_error(described_class::InvalidState, /already has a pending/)
      expect(statuses).to eq(%w[active pending])
    end
  end

  describe '#promote!' do
    it 'needs a pending key' do
      lifecycle.generate!

      expect { lifecycle.promote! }.to raise_error(described_class::InvalidState, /no pending key/)
    end

    it 'swaps active and retiring without ever leaving zero or two active keys' do
      old = lifecycle.generate!
      fresh = lifecycle.stage_next!
      advance(31.days)
      promoted = lifecycle.promote!

      expect(promoted).to eq(fresh)
      expect(statuses).to eq(%w[retiring active])
      expect(old.reload).to be_retiring
      expect(TenantSigningKey.where(tenant: tenant, status: 'active').count).to eq(1)
      expect(promoted.activated_at).to eq(t0 + 31.days)
      expect([old.reload.sequence, promoted.sequence].uniq).to eq([3])
    end

    it 'gives the new key the old key\'s last_signed_at, so the index counter never goes backwards' do
      old = lifecycle.generate!
      signed = Time.utc(2026, 11, 5, 8, 30, 15)
      old.update!(last_signed_at: signed)
      lifecycle.stage_next!
      promoted = lifecycle.promote!

      expect(promoted.last_signed_at).to eq(signed)
      expect(promoted.last_signed_at).to be >= old.reload.last_signed_at
    end

    it 'keeps the retiring key signing during the overlap, and both verify their own signatures' do
      old = lifecycle.generate!
      lifecycle.stage_next!
      fresh = lifecycle.promote!

      [old.reload, fresh].each do |key|
        expect(CatalogIndex::Ed25519.verify(key.public_key, 'bytes', key.sign('bytes'))).to be true
      end
    end

    it 'is refused while a retiring key still exists' do
      lifecycle.generate!
      lifecycle.stage_next!
      lifecycle.promote!
      lifecycle.stage_next!

      expect { lifecycle.promote! }.to raise_error(described_class::InvalidState, /still has a retiring key/)
      expect(statuses).to eq(%w[retiring active pending])
    end

    it 'rolls the whole step back when it fails half way' do
      lifecycle.generate!
      lifecycle.stage_next!
      before = TenantSigningKey.order(:id).pluck(:id, :status, :sequence)
      calls = 0
      allow_any_instance_of(TenantSigningKey).to receive(:update!).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::StatementInvalid, 'boom' if calls == 2

        original.call(*args)
      end

      expect { lifecycle.promote! }.to raise_error(ActiveRecord::StatementInvalid, 'boom')
      expect(calls).to eq(2)
      expect(TenantSigningKey.order(:id).pluck(:id, :status, :sequence)).to eq(before)
    end
  end

  describe '#retire!' do
    before do
      lifecycle.generate!
      lifecycle.stage_next!
      lifecycle.promote!
    end

    it 'needs a retiring key' do
      advance(91.days)
      lifecycle.retire!

      expect { lifecycle.retire! }.to raise_error(described_class::InvalidState, /no retiring key/)
    end

    it 'is refused before the overlap window has elapsed, and changes nothing' do
      advance(89.days)

      expect { lifecycle.retire! }.to raise_error(described_class::OverlapNotElapsed, /overlap ends at/)
      expect(statuses).to eq(%w[retiring active])
    end

    it 'retires after the window and destroys the old private key' do
      advance(90.days)
      retired = lifecycle.retire!

      expect(retired).to be_retired
      expect(retired.retired_at).to eq(now.first)
      expect(retired.reload.private_key_pem).to be_nil
      expect { retired.sign('x') }.to raise_error(TenantSigningKey::NotSigningError)
      expect(statuses).to eq(%w[retired active])
      expect(logger).not_to have_received(:warn)
    end

    it 'can be forced early, and that is logged' do
      advance(1.day)
      lifecycle.retire!(force: true)

      expect(statuses).to eq(%w[retired active])
      expect(logger).to have_received(:warn).with(/FORCED early retire.*acme/)
    end
  end

  describe 'the sequence counter' do
    it 'rises with every step and never repeats or decreases' do
      seen = [lifecycle.generate!.sequence]
      lifecycle.stage_next!
      seen << TenantSigningKey.maximum(:sequence)
      lifecycle.promote!
      seen << TenantSigningKey.maximum(:sequence)
      advance(91.days)
      lifecycle.retire!
      seen << TenantSigningKey.maximum(:sequence)
      lifecycle.stage_next!
      seen << TenantSigningKey.maximum(:sequence)

      expect(seen).to eq([1, 2, 3, 4, 5])
    end

    it 'is counted per tenant and purpose, not across tenants' do
      lifecycle.generate!
      lifecycle.stage_next!

      expect(described_class.new(other_tenant).generate!.sequence).to eq(1)
    end
  end

  describe 'a full rotation and the compromise hard cut' do
    it 'runs generate, stage, promote, retire, then a second rotation' do
      first = lifecycle.generate!
      second = lifecycle.stage_next!
      lifecycle.promote!
      advance(91.days)
      lifecycle.retire!
      third = lifecycle.stage_next!
      lifecycle.promote!

      expect(first.reload).to be_retired
      expect(second.reload).to be_retiring
      expect(third.reload).to be_active
      expect(statuses).to eq(%w[retired retiring active])
      expect(TenantSigningKey.where(tenant: tenant, status: 'active').count).to eq(1)
    end

    it 'supports the runbook\'s no-overlap hard cut: stage, promote, force-retire at once' do
      compromised = lifecycle.generate!
      lifecycle.stage_next!
      replacement = lifecycle.promote!
      lifecycle.retire!(force: true)

      expect(compromised.reload).to be_retired
      expect(compromised.private_key_pem).to be_nil
      expect(TenantSigningKey.active_for(tenant)).to eq(replacement)
    end
  end

  describe 'tenant isolation' do
    it 'never touches another tenant\'s keys' do
      other = described_class.new(other_tenant)
      other.generate!
      other.stage_next!
      snapshot = TenantSigningKey.where(tenant: other_tenant).order(:id).pluck(:id, :status, :sequence)

      lifecycle.generate!
      lifecycle.stage_next!
      lifecycle.promote!

      expect(TenantSigningKey.where(tenant: other_tenant).order(:id).pluck(:id, :status, :sequence)).to eq(snapshot)
    end
  end
end
