# frozen_string_literal: true

require 'rails_helper'

# Task 37b-ii-k6/k7: the tenant signing-key lifecycle from the browser (no shell on the Render free
# plan). Written by imitating admin_tenants_spec.rb; NOT run in the sandbox that wrote it (no Rails
# boot there), so it is the first thing to look at if CI is red for this slice. The lifecycle rules
# themselves are covered by spec/services/tenant_keys/lifecycle_spec.rb; this spec covers who may
# call them, what comes back, and that no private key material is ever rendered.
RSpec.describe 'Admin tenant keys', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:tenant) { create(:tenant, tenant_id: 'acme') }

  def keys_of(tenant) = TenantSigningKey.for_tenant(tenant).order(:id)

  context 'as an admin' do
    before { sign_in admin }

    it 'generates the first key as active and goes back to the edit page' do
      expect { post generate_admin_tenant_key_path(tenant) }.to change { keys_of(tenant).count }.by(1)

      expect(response).to redirect_to(edit_admin_tenant_path(tenant))
      key = TenantSigningKey.active_for(tenant)
      expect(key).to be_present
      expect(flash[:notice]).to include(key.key_id)
    end

    it 'refuses a second first key with a message and changes nothing' do
      create(:tenant_signing_key, tenant: tenant)

      expect { post generate_admin_tenant_key_path(tenant) }.not_to(change { keys_of(tenant).count })

      expect(response).to redirect_to(edit_admin_tenant_path(tenant))
      expect(flash[:alert]).to include('acme')
    end

    it 'stages, promotes, and refuses to retire before the overlap window ends' do
      old_key = create(:tenant_signing_key, tenant: tenant)

      post stage_next_admin_tenant_key_path(tenant)
      expect(keys_of(tenant).map(&:status)).to eq(%w[active pending])

      post promote_admin_tenant_key_path(tenant)
      expect(old_key.reload.status).to eq('retiring')
      expect(TenantSigningKey.active_for(tenant)).not_to eq(old_key)

      post retire_admin_tenant_key_path(tenant)
      expect(response).to redirect_to(edit_admin_tenant_path(tenant))
      expect(flash[:alert]).to be_present
      expect(old_key.reload.status).to eq('retiring')
    end

    it 'retires early only with force=1, and destroys the private key' do
      old_key = create(:tenant_signing_key, tenant: tenant)
      post stage_next_admin_tenant_key_path(tenant)
      post promote_admin_tenant_key_path(tenant)

      post retire_admin_tenant_key_path(tenant, force: 1)

      expect(old_key.reload.status).to eq('retired')
      expect(old_key.private_key_pem).to be_nil
      expect(flash[:notice]).to include(old_key.key_id)
    end

    it "never touches another tenant's keys" do
      other = create(:tenant, tenant_id: 'globex')
      other_key = create(:tenant_signing_key, tenant: other)

      post generate_admin_tenant_key_path(tenant)
      post stage_next_admin_tenant_key_path(tenant)
      post promote_admin_tenant_key_path(tenant)

      expect(keys_of(other).to_a).to eq([other_key])
      expect(other_key.reload.status).to eq('active')
    end

    it 'shows the public key on the edit page and never the private key' do
      key = create(:tenant_signing_key, tenant: tenant)

      get edit_admin_tenant_path(tenant)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(key.key_id, key.public_key)
      expect(response.body).not_to include('PRIVATE KEY')
      expect(response.body).not_to include(key.private_key_pem.to_s.lines.second.to_s.strip)
    end

    it 'offers only "Generate" for a tenant with no key' do
      get edit_admin_tenant_path(tenant)

      expect(response.body).to include(generate_admin_tenant_key_path(tenant))
      expect(response.body).not_to include(promote_admin_tenant_key_path(tenant))
    end

    it 'has no GET, index or destroy routes for keys' do
      %i[get delete].each do |verb|
        expect { Rails.application.routes.recognize_path("/admin/tenants/#{tenant.id}/key/promote", method: verb) }
          .to raise_error(ActionController::RoutingError)
      end
    end
  end

  context 'as a developer' do
    before do
      sign_in User.create!(email: 'dev@example.com', username: 'dev', password: password,
                           password_confirmation: password, confirmed_at: Time.current, role: :developer)
    end

    it 'cannot run any of the four steps' do
      key = create(:tenant_signing_key, tenant: tenant)

      [generate_admin_tenant_key_path(tenant), stage_next_admin_tenant_key_path(tenant),
       promote_admin_tenant_key_path(tenant), retire_admin_tenant_key_path(tenant, force: 1)].each do |path|
        post path
        expect(response).to have_http_status(:not_found)
      end

      expect(keys_of(tenant).to_a).to eq([key])
      expect(key.reload.status).to eq('active')
    end
  end
end
