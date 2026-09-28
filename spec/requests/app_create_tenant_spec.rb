# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-6: an app created on a tenant's host belongs to that tenant, and a non-member
# cannot create one at all. Default host: the app is created with no tenant, as before. Covers the
# API create and the console create. NOT run in the sandbox that wrote it (no Rails boot or
# database there).
RSpec.describe 'Creating an app and tenants', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }

  before { Zealot::TenantRegistry.reset! }

  describe 'POST /api/apps' do
    def post_app(name)
      post api_apps_path, params: { token: admin.token, name: name }
    end

    it 'creates the app with no tenant on the default host (unchanged)' do
      expect { post_app('Plain') }.to change(App, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(App.find_by(name: 'Plain').tenant_id).to be_nil
    end

    it 'refuses a non-member on a tenant host and creates nothing' do
      host! 'store.acme.example.com'

      expect { post_app('Nope') }.not_to change(App, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'stamps the tenant when a member creates one' do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'

      expect { post_app('Acme thing') }.to change(App, :count).by(1)

      expect(App.find_by(name: 'Acme thing').tenant_id).to eq(acme.id)
    end
  end

  describe 'POST /apps (console)' do
    before { sign_in admin }

    it 'refuses a non-member on a tenant host and creates nothing' do
      host! 'store.acme.example.com'

      expect { post apps_path, params: { app: { name: 'Nope' } } }.not_to change(App, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'stamps the tenant when a member creates one' do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'

      post apps_path, params: { app: { name: 'Acme console' } }

      expect(App.find_by(name: 'Acme console')&.tenant_id).to eq(acme.id)
    end
  end
end
