# frozen_string_literal: true

# The code under test is pure Ruby (no DB), but specs here go through `rails_helper` like the
# rest of the suite so `Zealot::TenantResolver` autoloads exactly as it does in the app.
require 'rails_helper'

RSpec.describe Zealot::TenantResolver do
  let(:tenant_class) { Struct.new(:tenant_id, :domains) }
  let(:acme)   { tenant_class.new('acme', ['store.acme.com', 'apps.acme.io']) }
  let(:globex) { tenant_class.new('globex', ['store.globex.com']) }

  describe '.normalize_host' do
    it 'lowercases, strips port and trailing dot' do
      expect(described_class.normalize_host(' Store.Acme.COM:8443. ')).to eq('store.acme.com')
      expect(described_class.normalize_host('store.acme.com.')).to eq('store.acme.com')
    end

    it 'returns nil for nil, empty, IPv6 literals and junk' do
      [nil, '', '   ', '[::1]:3000', 'a b.com', 'evil.com/../x', '-bad.com', 'a..b', ('a' * 254)].each do |raw|
        expect(described_class.normalize_host(raw)).to be_nil, "expected #{raw.inspect} => nil"
      end
    end
  end

  describe '.resolve' do
    it 'falls back to the default tenant for nil host and unknown hosts' do
      expect(described_class.resolve(nil, tenants: [acme])).to eq(described_class::DEFAULT_TENANT)
      expect(described_class.resolve('localhost', tenants: [acme])).to eq(described_class::DEFAULT_TENANT)
      expect(described_class.resolve('x.com', tenants: [])).to eq(described_class::DEFAULT_TENANT)
    end

    it 'resolves an exact domain match' do
      expect(described_class.resolve('apps.acme.io', tenants: [acme, globex])).to eq(acme)
      expect(described_class.resolve('store.globex.com', tenants: [acme, globex])).to eq(globex)
    end

    it 'resolves a contested domain to the default tenant regardless of order' do
      thief = tenant_class.new('thief', ['store.acme.com'])
      expect(described_class.resolve('store.acme.com', tenants: [acme, thief])).to eq(described_class::DEFAULT_TENANT)
      expect(described_class.resolve('store.acme.com', tenants: [thief, acme])).to eq(described_class::DEFAULT_TENANT)
    end

    it 'drops a record claiming the default tenant id' do
      fake = tenant_class.new('default', ['evil.com'])
      expect(described_class.resolve('evil.com', tenants: [fake])).to eq(described_class::DEFAULT_TENANT)
    end

    it 'resolves <tenant_id>.<base_domain>, single label only' do
      kw = { tenants: [acme], base_domain: 'stores.example.com' }
      expect(described_class.resolve('acme.stores.example.com', **kw)).to eq(acme)
      expect(described_class.resolve('a.acme.stores.example.com', **kw)).to eq(described_class::DEFAULT_TENANT)
      expect(described_class.resolve('nobody.stores.example.com', **kw)).to eq(described_class::DEFAULT_TENANT)
      expect(described_class.resolve('acme.stores.example.com', tenants: [acme], base_domain: nil))
        .to eq(described_class::DEFAULT_TENANT)
    end
  end

  describe '.annotate!' do
    around do |ex|
      old = described_class.instance_variable_get(:@registry)
      described_class.registry = -> { [acme] }
      ex.run
      described_class.instance_variable_set(:@registry, old)
    end

    it 'sets the host and tenant from HTTP_HOST' do
      env = described_class.annotate!('HTTP_HOST' => 'Store.Acme.com:443')
      expect(env['zealot.tenant_host']).to eq('store.acme.com')
      expect(env['zealot.tenant']).to eq(acme)
    end

    it 'ignores X-Forwarded-Host and deletes a client-supplied X-Tenant-Host' do
      env = described_class.annotate!(
        'HTTP_HOST' => 'unknown.example.org',
        'HTTP_X_FORWARDED_HOST' => 'store.acme.com',
        'HTTP_X_TENANT_HOST' => 'store.acme.com'
      )
      expect(env['zealot.tenant']).to eq(described_class::DEFAULT_TENANT)
      expect(env).not_to have_key('HTTP_X_TENANT_HOST')
    end

    it 'overwrites pre-seeded zealot.* keys' do
      env = described_class.annotate!('HTTP_HOST' => 'unknown.example.org', 'zealot.tenant' => acme)
      expect(env['zealot.tenant']).to eq(described_class::DEFAULT_TENANT)
    end

    it 'fails closed to the default tenant if the registry raises' do
      described_class.registry = -> { raise 'db down' }
      env = described_class.annotate!('HTTP_HOST' => 'store.acme.com')
      expect(env['zealot.tenant']).to eq(described_class::DEFAULT_TENANT)
    end

    it 'handles a missing Host header' do
      env = described_class.annotate!({})
      expect(env['zealot.tenant_host']).to be_nil
      expect(env['zealot.tenant']).to eq(described_class::DEFAULT_TENANT)
    end
  end
end
