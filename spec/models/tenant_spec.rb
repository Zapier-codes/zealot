# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-t1: the Tenant record (fields per TenantConfig v1, Task 37a). Built with the
# `tenant` factory; needs Postgres (jsonb, check constraints, the domain-overlap query).
RSpec.describe Tenant do
  describe 'the factory' do
    it 'builds a valid tenant' do
      expect(build(:tenant)).to be_valid
    end
  end

  describe 'tenant_id' do
    it 'is refused when it is the reserved default tenant' do
      expect(build(:tenant, tenant_id: 'default')).not_to be_valid
    end

    it 'is lowercased and stripped before validation' do
      tenant = build(:tenant, tenant_id: '  Acme-Store ')
      expect(tenant).to be_valid
      expect(tenant.tenant_id).to eq('acme-store')
    end

    it 'rejects anything that is not a DNS label' do
      ['acme_store', '-acme', 'acme-', 'ac me', 'a' * 64, ''].each do |bad|
        expect(build(:tenant, tenant_id: bad)).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'accepts a 63-character label and a single character' do
      expect(build(:tenant, tenant_id: 'a' * 63)).to be_valid
      expect(build(:tenant, tenant_id: 'a')).to be_valid
    end

    it 'must be unique' do
      create(:tenant, tenant_id: 'acme')
      expect(build(:tenant, tenant_id: 'acme')).not_to be_valid
    end

    it 'cannot be changed once the tenant exists' do
      tenant = create(:tenant, tenant_id: 'acme')
      # Depending on `raise_on_assign_to_attr_readonly`, the assignment either raises or the
      # validation refuses it; either way nothing is persisted.
      result = begin
        tenant.update(tenant_id: 'other')
      rescue ActiveRecord::ReadonlyAttributeError
        false
      end

      expect(result).to be(false)
      expect(tenant.reload.tenant_id).to eq('acme')
    end
  end

  describe 'required fields' do
    it 'needs display_name, primary_color_hex and cdn_base' do
      %i[display_name primary_color_hex cdn_base].each do |attr|
        expect(build(:tenant, attr => nil)).not_to be_valid, "expected #{attr} to be required"
      end
    end

    it 'needs primary_color_hex to be #RRGGBB' do
      expect(build(:tenant, primary_color_hex: '#ff6600')).to be_valid
      ['FF6600', '#FF66', '#GG6600', 'red'].each do |bad|
        expect(build(:tenant, primary_color_hex: bad)).not_to be_valid
      end
    end
  end

  describe 'URLs' do
    it 'accepts https URLs for cdn_base, catalog_index_base_url and logo_url' do
      tenant = build(:tenant, catalog_index_base_url: 'https://acme.example.com/zealot-index',
                              logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'a' * 64)
      expect(tenant).to be_valid
    end

    it 'refuses http, non-URLs and hostless values' do
      ['http://cdn.example.com', 'cdn.example.com', 'https://', 'javascript:alert(1)'].each do |bad|
        expect(build(:tenant, cdn_base: bad)).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'treats a blank optional URL as absent' do
      tenant = build(:tenant, catalog_index_base_url: '', logo_url: '')
      expect(tenant).to be_valid
      expect(tenant.catalog_index_base_url).to be_nil
      expect(tenant.logo_url).to be_nil
    end
  end

  describe 'logo_sha256' do
    it 'is required when logo_url is present' do
      expect(build(:tenant, logo_url: 'https://acme.example.com/logo.png')).not_to be_valid
    end

    it 'must be 64 lowercase hex characters, and is downcased first' do
      tenant = build(:tenant, logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'A' * 64)
      expect(tenant).to be_valid
      expect(tenant.logo_sha256).to eq('a' * 64)
      expect(build(:tenant, logo_url: 'https://acme.example.com/logo.png', logo_sha256: 'abc')).not_to be_valid
    end
  end

  describe 'domains' do
    it 'defaults to empty, which is valid (not resolved by domain)' do
      expect(create(:tenant).domains).to eq([])
    end

    it 'normalizes like the resolver: case, port, trailing dot, duplicates' do
      tenant = create(:tenant, domains: ['Store.Acme.Example.com:8080', 'store.acme.example.com.', 'shop.acme.example.com'])
      expect(tenant.domains).to eq(%w[store.acme.example.com shop.acme.example.com])
    end

    it 'refuses entries that are not plain hostnames' do
      ['[::1]', 'not a host', 'a_b.example.com', 'https://store.example.com'].each do |bad|
        expect(build(:tenant, domains: [bad])).not_to be_valid, "expected #{bad.inspect} to be invalid"
      end
    end

    it 'refuses a domain another tenant already claims' do
      create(:tenant, domains: ['store.acme.example.com'])
      other = build(:tenant, domains: ['shop.other.example.com', 'STORE.acme.example.com'])

      expect(other).not_to be_valid
      expect(other.errors[:domains]).to be_present
    end

    it 'does not conflict with its own domains on update' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      expect(tenant.update(display_name: 'Renamed')).to be(true)
      expect(tenant.update(domains: ['store.acme.example.com', 'new.acme.example.com'])).to be(true)
    end
  end

  describe 'Zealot::TenantResolver contract' do
    it 'is resolved by its domain through the resolver' do
      tenant = create(:tenant, domains: ['store.acme.example.com'])
      resolved = Zealot::TenantResolver.resolve('store.acme.example.com', tenants: [tenant], base_domain: nil)

      expect(resolved).to eq(tenant)
    end

    it 'leaves a contested domain to the default tenant' do
      a = create(:tenant, domains: ['store.acme.example.com'])
      b = create(:tenant, domains: ['shop.other.example.com'])
      # Both claim it only if the validation was bypassed (the race the model can't close).
      b.update_columns(domains: ['store.acme.example.com'])

      resolved = Zealot::TenantResolver.resolve('store.acme.example.com', tenants: [a, b], base_domain: nil)
      expect(resolved.tenant_id).to eq(Zealot::TenantResolver::DEFAULT_TENANT_ID)
    end
  end
end
