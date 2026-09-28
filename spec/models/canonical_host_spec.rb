# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7b: `Tenant#canonical_host`, `Tenant.default_canonical_host` and
# `Channel#canonical_host`. Needs Postgres. NOT run in the sandbox that wrote it (no Rails boot or
# database there), so it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Canonical host' do
  let(:base_domain) { nil }

  before do
    Zealot::TenantRegistry.reset!
    allow(Zealot::TenantResolver).to receive(:base_domain).and_return(base_domain)
  end

  def channel_for(app)
    scheme = app.schemes.create!(name: 'Main')
    scheme.channels.create!(name: 'Android', device_type: :android)
  end

  describe Tenant do
    it 'is its first claimed domain' do
      tenant = create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com', 'shop.acme.example.com'])

      expect(tenant.canonical_host).to eq('store.acme.example.com')
    end

    it 'is nil when it has no domain and there is no base domain (callers then do not redirect)' do
      expect(create(:tenant, tenant_id: 'acme', domains: []).canonical_host).to be_nil
    end

    context 'with a base domain' do
      let(:base_domain) { 'stores.example.net' }

      it 'falls back to <tenant_id>.<base domain>' do
        expect(create(:tenant, tenant_id: 'acme', domains: []).canonical_host).to eq('acme.stores.example.net')
      end

      it 'still prefers a claimed domain' do
        tenant = create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com'])

        expect(tenant.canonical_host).to eq('store.acme.example.com')
      end
    end
  end

  describe 'Tenant.default_canonical_host' do
    it 'is ZEALOT_DOMAIN without a port' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('Zealot.Example.org:8443')

      expect(Tenant.default_canonical_host).to eq('zealot.example.org')
    end

    it 'is nil when the host is claimed by a tenant (a redirect there would not land on the default site)' do
      create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com'])
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('store.acme.example.com')

      expect(Tenant.default_canonical_host).to be_nil
    end
  end

  describe Channel do
    it 'follows the owning app\'s tenant' do
      tenant = create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com'])

      expect(channel_for(create(:app, tenant: tenant)).canonical_host).to eq('store.acme.example.com')
    end

    it 'is the default host for a default-tenant app' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('zealot.example.org')

      expect(channel_for(create(:app)).canonical_host).to eq('zealot.example.org')
    end
  end
end
