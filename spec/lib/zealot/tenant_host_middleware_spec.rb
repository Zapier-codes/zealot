# frozen_string_literal: true

require 'rails_helper'

# Rack-level check of the shim in config/initializers/tenant_host.rb, driven through the
# resolver's registry hook (the initializer points that hook at Zealot::TenantRegistry).
RSpec.describe TenantHostMiddleware do
  let(:app) { ->(env) { [200, {}, [env[Zealot::TenantResolver::ENV_TENANT_KEY].tenant_id]] } }
  let(:middleware) { described_class.new(app) }
  let(:default_id) { Zealot::TenantResolver::DEFAULT_TENANT_ID }
  let(:ref_class) { Zealot::TenantResolver::Ref }

  around do |ex|
    old = Zealot::TenantResolver.instance_variable_get(:@registry)
    ex.run
  ensure
    Zealot::TenantResolver.instance_variable_set(:@registry, old)
  end

  def tenant_for(host)
    status, _headers, body = middleware.call(Rack::MockRequest.env_for('/', 'HTTP_HOST' => host))
    expect(status).to eq(200)
    body.first
  end

  it 'resolves a known tenant domain, and everything else to the default tenant' do
    Zealot::TenantResolver.registry = -> { [ref_class.new('acme', ['store.acme.com'])] }
    expect(tenant_for('store.acme.com')).to eq('acme')
    expect(tenant_for('STORE.ACME.COM:443')).to eq('acme')
    expect(tenant_for('unknown.example.com')).to eq(default_id)
    expect(tenant_for(nil)).to eq(default_id)
  end

  it 'resolves to the default tenant when the registry raises (fails closed)' do
    Zealot::TenantResolver.registry = -> { raise ActiveRecord::StatementInvalid, 'relation "tenants" does not exist' }
    expect(tenant_for('store.acme.com')).to eq(default_id)
  end

  it 'resolves to the default tenant when a real TenantRegistry cannot read the table' do
    unreadable = Zealot::TenantRegistry.new(source: -> { raise PG::UndefinedTable, 'x' }, logger: nil)
    Zealot::TenantResolver.registry = -> { unreadable.call }
    expect(tenant_for('store.acme.com')).to eq(default_id)
  end

  it 'never lets a client pick its tenant through X-Tenant-Host or X-Forwarded-Host' do
    Zealot::TenantResolver.registry = -> { [ref_class.new('acme', ['store.acme.com'])] }
    env = Rack::MockRequest.env_for('/', 'HTTP_HOST' => 'unknown.example.com',
                                        'HTTP_X_TENANT_HOST' => 'store.acme.com',
                                        'HTTP_X_FORWARDED_HOST' => 'store.acme.com')
    _status, _headers, body = middleware.call(env)
    expect(body.first).to eq(default_id)
    expect(env).not_to have_key('HTTP_X_TENANT_HOST')
  end
end
