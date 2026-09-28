# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-t3: the tenant admin views. Written by imitating the other request specs; NOT run
# in the sandbox that wrote it (no Rails boot there), so it is the first thing to look at if CI
# is red for this slice.
RSpec.describe 'Admin tenants', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:valid_params) do
    { tenant: { tenant_id: 'acme', display_name: 'Acme Store', primary_color_hex: '#FF6600',
                cdn_base: 'https://cdn.acme.example.com/meta', domains_text: "store.acme.example.com\n" } }
  end

  context 'as an admin' do
    before { sign_in admin }

    it 'lists tenants' do
      create(:tenant, tenant_id: 'acme')
      get admin_tenants_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('acme')
    end

    it 'creates a tenant and drops the registry cache' do
      allow(Zealot::TenantRegistry).to receive(:reset!)

      expect { post admin_tenants_path, params: valid_params }.to change(Tenant, :count).by(1)

      expect(response).to redirect_to(admin_tenants_path)
      expect(Tenant.find_by!(tenant_id: 'acme').domains).to eq(['store.acme.example.com'])
      expect(Zealot::TenantRegistry).to have_received(:reset!).at_least(:once)
    end

    it 're-renders the form when the tenant claims this deployment\'s own host' do
      allow(Tenant).to receive(:reserved_hosts).and_return(['console.example.com'])
      valid_params[:tenant][:domains_text] = 'console.example.com'

      expect { post admin_tenants_path, params: valid_params }.not_to change(Tenant, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'edits everything but tenant_id' do
      tenant = create(:tenant, tenant_id: 'acme')

      patch admin_tenant_path(tenant), params: { tenant: { tenant_id: 'renamed', display_name: 'New name' } }

      expect(response).to redirect_to(admin_tenants_path)
      expect(tenant.reload.display_name).to eq('New name')
      expect(tenant.tenant_id).to eq('acme')
    end

    it 'has no destroy route' do
      expect { Rails.application.routes.recognize_path('/admin/tenants/1', method: :delete) }
        .to raise_error(ActionController::RoutingError)
    end
  end

  context 'as a developer' do
    before do
      sign_in User.create!(email: 'dev@example.com', username: 'dev', password: password,
                           password_confirmation: password, confirmed_at: Time.current, role: :developer)
    end

    it 'cannot reach the list or create a tenant' do
      get admin_tenants_path
      expect(response).to have_http_status(:not_found)

      expect { post admin_tenants_path, params: valid_params }.not_to change(Tenant, :count)
    end
  end
end
