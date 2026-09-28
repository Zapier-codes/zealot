# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-k4. See app/services/catalog_index/key_resolver.rb.
RSpec.describe CatalogIndex::KeyResolver do
  let(:tenant_a) { create(:tenant, tenant_id: 'acme') }
  let(:tenant_b) { create(:tenant, tenant_id: 'globex') }

  describe 'the default tenant' do
    it 'resolves to the catalog-index key, however the default tenant is named' do
      key = CatalogIndexSigningKey.generate!

      [nil, '', 'default', 'DEFAULT', Zealot::TenantResolver::DEFAULT_TENANT].each do |tenant|
        expect(described_class.for(tenant)).to eq(key), "expected #{tenant.inspect} to be the default tenant"
      end
    end

    it 'has no key yet -> nil / [], not an error (Signer keeps its own generate_key message)' do
      expect(described_class.for(nil)).to be_nil
      expect(described_class.signing_keys_for(nil)).to eq([])
    end

    it 'never returns a tenant key, even when tenants have keys' do
      key = CatalogIndexSigningKey.generate!
      create(:tenant_signing_key, tenant: tenant_a)

      expect(described_class.for(nil)).to eq(key)
    end
  end

  describe 'another tenant' do
    it 'resolves to its own active key, from a Tenant, a Ref or a tenant id' do
      key = create(:tenant_signing_key, tenant: tenant_a)
      ref = Zealot::TenantResolver::Ref.new('acme', [])

      [tenant_a, ref, 'acme', ' ACME '].each do |tenant|
        expect(described_class.for(tenant)).to eq(key)
      end
    end

    it 'never selects another tenant\'s key' do
      key_a = create(:tenant_signing_key, tenant: tenant_a)
      key_b = create(:tenant_signing_key, tenant: tenant_b)

      expect(described_class.for(tenant_a)).to eq(key_a)
      expect(described_class.for(tenant_b)).to eq(key_b)
      expect(described_class.signing_keys_for(tenant_a)).not_to include(key_b)
    end

    it 'raises, naming the tenant, and does NOT fall back to the default key, when it has no key' do
      CatalogIndexSigningKey.generate!
      tenant_a

      expect { described_class.for('acme') }.to raise_error(described_class::NoKeyError, /acme/)
    end

    it 'raises for a tenant that does not exist, naming it' do
      expect { described_class.for('nope') }.to raise_error(described_class::NoKeyError, /nope/)
    end

    it 'is a Signer::NoKeyError, so existing rescues keep working' do
      expect(described_class::NoKeyError.ancestors).to include(CatalogIndex::Signer::NoKeyError)
    end

    it 'does not treat a tenant with only a retiring or pending key as signable' do
      create(:tenant_signing_key, :retiring, tenant: tenant_a)
      create(:tenant_signing_key, :pending, tenant: tenant_a)

      expect { described_class.for(tenant_a) }.to raise_error(described_class::NoKeyError, /no active/)
    end
  end

  describe '.signing_keys_for during a rotation' do
    it 'lists the active key first, then the retiring one, and leaves out pending and retired keys' do
      lifecycle = TenantKeys::Lifecycle.new(tenant_a)
      old = lifecycle.generate!
      lifecycle.stage_next!
      fresh = lifecycle.promote!
      lifecycle.stage_next!

      expect(described_class.signing_keys_for(tenant_a)).to eq([fresh, old])
      expect(described_class.for(tenant_a)).to eq(fresh)

      lifecycle.retire!(force: true)
      expect(described_class.signing_keys_for(tenant_a)).to eq([fresh])
    end
  end
end
