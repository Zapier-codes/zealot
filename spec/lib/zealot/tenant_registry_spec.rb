# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Zealot::TenantRegistry do
  let(:now) { [100.0] }
  let(:clock) { -> { now.first } }
  let(:calls) { [] }
  let(:rows) { [['acme', ['store.acme.com']]] }
  let(:source) { -> { calls << 1; rows } }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:registry) { described_class.new(source: source, ttl: 30, failure_ttl: 5, clock: clock, logger: logger) }

  def advance(seconds)
    now[0] += seconds
  end

  describe '#call' do
    it 'returns frozen tenant_id/domains snapshots, not source rows' do
      tenant = registry.call.first
      expect(tenant).to be_a(Zealot::TenantResolver::Ref)
      expect([tenant.tenant_id, tenant.domains]).to eq(['acme', ['store.acme.com']])
      expect(registry.call).to be_frozen
      expect(tenant).to be_frozen
      expect(tenant.domains).to be_frozen
    end

    it 'returns no tenants when there are none' do
      expect(described_class.new(source: -> { [] }, ttl: 30, clock: clock).call).to eq([])
    end

    it 'queries once inside the TTL and again after it' do
      registry.call
      advance(29)
      registry.call
      expect(calls.size).to eq(1)
      advance(2)
      registry.call
      expect(calls.size).to eq(2)
    end

    it 'queries every time when the TTL is 0' do
      zero = described_class.new(source: source, ttl: 0, clock: clock)
      3.times { zero.call }
      expect(calls.size).to eq(3)
    end

    it 'picks up a changed table after the TTL' do
      expect(registry.call.map(&:tenant_id)).to eq(['acme'])
      rows << ['globex', ['store.globex.com']]
      expect(registry.call.map(&:tenant_id)).to eq(['acme'])
      advance(31)
      expect(registry.call.map(&:tenant_id)).to eq(%w[acme globex])
    end

    it 'refreshes on the next call after reset!' do
      registry.call
      registry.reset!
      registry.call
      expect(calls.size).to eq(2)
    end

    it 'coalesces concurrent callers on an expired cache into one query' do
      slow = -> { calls << 1; sleep 0.05; rows }
      shared = described_class.new(source: slow, ttl: 30, clock: clock)
      Array.new(8) { Thread.new { shared.call } }.each(&:join)
      expect(calls.size).to eq(1)
    end
  end

  describe 'failure handling (fails closed to no tenants)' do
    let(:missing_table) { 'PG::UndefinedTable: relation "tenants" does not exist' }
    let(:source) { -> { calls << 1; raise ActiveRecord::StatementInvalid, missing_table } }

    it 'returns no tenants, logs, and does not raise' do
      expect(registry.call).to eq([])
      expect(logger).to have_received(:warn).with(/tenant-registry.*default tenant.*UndefinedTable/)
    end

    it 'does not hammer a broken database: one attempt per failure TTL' do
      3.times { registry.call }
      expect(calls.size).to eq(1)
      advance(6)
      registry.call
      expect(calls.size).to eq(2)
    end

    it 'recovers once the source works again, and does NOT keep serving old tenants after a failure' do
      good = described_class.new(source: -> { rows }, ttl: 30, failure_ttl: 5, clock: clock, logger: logger)
      flaky_rows = [['acme', ['store.acme.com']]]
      failing = false
      flaky = described_class.new(
        source: -> { raise 'db down' if failing; flaky_rows }, ttl: 10, failure_ttl: 5, clock: clock, logger: logger
      )
      expect(good.call.size).to eq(1)
      expect(flaky.call.size).to eq(1)
      failing = true
      advance(11)
      expect(flaky.call).to eq([])
      failing = false
      advance(6)
      expect(flaky.call.size).to eq(1)
    end
  end

  describe '.default_ttl' do
    around do |ex|
      old = ENV['TENANT_REGISTRY_TTL']
      ex.run
    ensure
      ENV['TENANT_REGISTRY_TTL'] = old
    end

    it 'reads TENANT_REGISTRY_TTL, ignoring blank, negative or junk values' do
      ENV['TENANT_REGISTRY_TTL'] = '12'
      expect(described_class.default_ttl).to eq(12.0)
      ENV['TENANT_REGISTRY_TTL'] = '0'
      expect(described_class.default_ttl).to eq(0.0)
      ['', '-3', 'abc'].each do |bad|
        ENV['TENANT_REGISTRY_TTL'] = bad
        expect(described_class.default_ttl).to eq(0), "expected #{bad.inspect} to fall back (0 in the test env)"
      end
    end
  end

  describe 'against the real tenants table (default source)' do
    let(:db_registry) { described_class.new(ttl: 0, clock: clock, logger: logger) }

    it 'is empty with no rows, so every host resolves to the default tenant' do
      expect(db_registry.call).to eq([])
      expect(Zealot::TenantResolver.resolve('store.acme.com', tenants: db_registry.call))
        .to eq(Zealot::TenantResolver::DEFAULT_TENANT)
    end

    it 'resolves a tenant row\'s domain to that tenant, and an unknown host to the default' do
      create(:tenant, tenant_id: 'acme', domains: ['Store.Acme.com'])
      create(:tenant, tenant_id: 'globex', domains: ['store.globex.com'])
      tenants = db_registry.call

      expect(tenants.map(&:tenant_id)).to eq(%w[acme globex])
      expect(Zealot::TenantResolver.resolve('store.acme.com', tenants: tenants).tenant_id).to eq('acme')
      expect(Zealot::TenantResolver.resolve('store.globex.com', tenants: tenants).tenant_id).to eq('globex')
      expect(Zealot::TenantResolver.resolve('other.example.com', tenants: tenants))
        .to eq(Zealot::TenantResolver::DEFAULT_TENANT)
    end
  end
end
