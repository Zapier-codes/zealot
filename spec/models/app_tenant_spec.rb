# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s2 (`apps.tenant_id`, `App belongs_to :tenant`) and s3 (`App.for_tenant`).
# Needs Postgres: the column is a real foreign key and `Tenant#apps` is `restrict_with_error`.
RSpec.describe App, 'tenant ownership' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }

  describe 'apps.tenant_id (s2)' do
    it 'leaves a new app in the default catalog: no tenant' do
      expect(create(:app).tenant).to be_nil
      expect(create(:app).tenant_id).to be_nil
    end

    it 'lets an app be assigned to a tenant' do
      app = create(:app, tenant: acme)

      expect(app.reload.tenant).to eq(acme)
      expect(acme.apps).to contain_exactly(app)
    end

    it 'lets an app be moved back to the default catalog by clearing the tenant' do
      app = create(:app, tenant: acme)

      app.update!(tenant: nil)

      expect(app.reload.tenant_id).to be_nil
    end

    it 'refuses to point at a tenant row that does not exist (foreign key)' do
      app = create(:app)

      expect { app.update_columns(tenant_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe 'Tenant#destroy' do
    it 'is refused while the tenant owns apps, and the apps are left alone' do
      app = create(:app, tenant: acme)

      expect(acme.destroy).to be(false)
      expect(acme.errors[:base]).to be_present
      expect(Tenant.exists?(acme.id)).to be(true)
      expect(app.reload.tenant).to eq(acme)
    end

    it 'still works for a tenant that owns no apps' do
      empty = create(:tenant, tenant_id: 'empty')

      expect(empty.destroy).to be_truthy
    end
  end

  describe '.for_tenant (s3)' do
    let!(:default_app) { create(:app) }
    let!(:acme_app) { create(:app, tenant: acme) }
    let!(:globex_app) { create(:app, tenant: globex) }

    it 'gives the default tenant exactly the apps that have no tenant' do
      [nil, '', 'default', ' Default ', Zealot::TenantResolver::DEFAULT_TENANT].each do |default|
        expect(App.for_tenant(default)).to contain_exactly(default_app), "expected #{default.inspect} to be the default tenant"
      end
    end

    it 'gives another tenant only its own apps, never the default tenant\'s or another tenant\'s' do
      expect(App.for_tenant(acme)).to contain_exactly(acme_app)
      expect(App.for_tenant(globex)).to contain_exactly(globex_app)
    end

    it 'accepts a tenant id string (any case) and a resolver Ref, not only the record' do
      ref = Zealot::TenantResolver::Ref.new('acme', [].freeze)

      expect(App.for_tenant('acme')).to contain_exactly(acme_app)
      expect(App.for_tenant('ACME')).to contain_exactly(acme_app)
      expect(App.for_tenant(ref)).to contain_exactly(acme_app)
    end

    it 'gives an unknown tenant NOTHING, and never falls back to the default catalog' do
      expect(App.for_tenant('no-such-tenant')).to be_empty
    end

    it 'composes with other scopes' do
      create(:app, tenant: acme, archived: true)

      expect(App.for_tenant(acme).active).to contain_exactly(acme_app)
    end
  end
end
