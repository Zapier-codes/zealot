# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-1: `TenantScoped#current_tenant` / `#default_host?`. The concern is exercised on a
# plain object with a fake `request`, so no route or controller is needed; the methods are private
# on purpose (a public controller method is a routable action), hence `send`. Needs Postgres for the
# `Tenant` rows. Written by imitating tenant_host_middleware_spec.rb; NOT run in the sandbox that
# wrote it (no Rails boot or database there).
RSpec.describe TenantScoped do
  let(:key) { Zealot::TenantResolver::ENV_TENANT_KEY }
  let(:ref_class) { Zealot::TenantResolver::Ref }

  let(:host_class) do
    Class.new do
      include TenantScoped

      def initialize(env) = @env = env
      def request = Struct.new(:env).new(@env)
    end
  end

  def controller_for(env) = host_class.new(env)
  def current_tenant(controller) = controller.send(:current_tenant)
  def default_host?(controller) = controller.send(:default_host?)

  describe 'on the default host' do
    it 'is nil and default_host? is true, with no database query' do
      controller = controller_for(key => Zealot::TenantResolver::DEFAULT_TENANT)

      expect(Tenant).not_to receive(:find_by)
      expect(current_tenant(controller)).to be_nil
      expect(default_host?(controller)).to be(true)
    end

    it 'reads a missing env key as the default host' do
      controller = controller_for({})

      expect(current_tenant(controller)).to be_nil
      expect(default_host?(controller)).to be(true)
    end
  end

  describe 'on a tenant host' do
    let!(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }

    it 'is that tenant row, from the resolver ref' do
      controller = controller_for(key => ref_class.new('acme', ['store.acme.example.com']))

      expect(current_tenant(controller)).to eq(acme)
      expect(default_host?(controller)).to be(false)
    end

    it 'is that tenant row when the env carries the Tenant itself' do
      controller = controller_for(key => acme)

      expect(current_tenant(controller)).to eq(acme)
    end

    it 'looks the tenant up once per request' do
      controller = controller_for(key => ref_class.new('acme', []))

      expect(Tenant).to receive(:find_by).once.and_call_original
      3.times { current_tenant(controller) }
      expect(default_host?(controller)).to be(false)
    end

    it 'reads a ref whose tenant row no longer exists as the default host' do
      controller = controller_for(key => ref_class.new('gone', ['gone.example.com']))

      expect(current_tenant(controller)).to be_nil
      expect(default_host?(controller)).to be(true)
    end

    it 'does not rescue a database error (the access rule must not fail open)' do
      allow(Tenant).to receive(:find_by).and_raise(ActiveRecord::StatementInvalid, 'boom')
      controller = controller_for(key => ref_class.new('acme', []))

      expect { current_tenant(controller) }.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'wiring into ApplicationController' do
    it 'is included, and its readers are private (never routable actions)' do
      expect(ApplicationController.ancestors).to include(described_class)
      expect(ApplicationController.private_instance_methods).to include(:current_tenant, :default_host?)
      expect(ApplicationController.public_instance_methods).not_to include(:current_tenant, :default_host?)
    end

    it 'exposes both to views as helpers' do
      expect(ApplicationController._helper_methods).to include(:current_tenant, :default_host?)
    end
  end
end
