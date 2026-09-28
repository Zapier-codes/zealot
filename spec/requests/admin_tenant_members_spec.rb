# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-7: add, re-role and remove tenant members from the admin console. Only a platform
# admin on the default host; the tenant's only owner cannot be removed or demoted. Written by
# imitating admin_tenant_keys_spec.rb; NOT run in the sandbox that wrote it (no Rails boot or
# database there), so it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Admin tenant members', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:developer) do
    User.create!(email: 'dev@example.com', username: 'dev', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :developer)
  end
  let(:tenant) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }

  before { Zealot::TenantRegistry.reset! }

  context 'as a platform admin on the default host' do
    before { sign_in admin }

    it 'shows the panel on the tenant edit page' do
      get edit_admin_tenant_path(tenant)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(admin_tenant_memberships_path(tenant))
    end

    it 'adds an existing user by email, as a member by default' do
      developer

      expect { post admin_tenant_memberships_path(tenant), params: { email: ' DEV@example.com ' } }
        .to change { TenantMembership.for_tenant(tenant).count }.by(1)

      expect(response).to redirect_to(edit_admin_tenant_path(tenant))
      expect(TenantMembership.find_by(user: developer, tenant: tenant).role).to eq('member')
      expect(flash[:notice]).to include('dev@example.com')
    end

    it 'adds an owner when asked' do
      developer
      post admin_tenant_memberships_path(tenant), params: { email: developer.email, role: 'owner' }

      expect(TenantMembership.find_by(user: developer, tenant: tenant).role).to eq('owner')
    end

    it 'says so, and adds nothing, for an unknown email, a bad role or a duplicate' do
      developer
      expect { post admin_tenant_memberships_path(tenant), params: { email: 'nobody@example.com' } }
        .not_to change(TenantMembership, :count)
      expect(flash[:alert]).to include('nobody@example.com')

      expect { post admin_tenant_memberships_path(tenant), params: { email: developer.email, role: 'root' } }
        .not_to change(TenantMembership, :count)

      create(:tenant_membership, tenant: tenant, user: developer)
      expect { post admin_tenant_memberships_path(tenant), params: { email: developer.email } }
        .not_to change(TenantMembership, :count)
      expect(flash[:alert]).to include(developer.email)
    end

    it 'changes a member\'s role' do
      membership = create(:tenant_membership, tenant: tenant, user: developer)

      patch admin_tenant_membership_path(tenant, membership), params: { role: 'owner' }

      expect(membership.reload.role).to eq('owner')
    end

    it 'removes a member' do
      membership = create(:tenant_membership, tenant: tenant, user: developer)

      expect { delete admin_tenant_membership_path(tenant, membership) }.to change(TenantMembership, :count).by(-1)
      expect(response).to redirect_to(edit_admin_tenant_path(tenant))
    end

    it 'refuses to remove or demote the only owner, but allows it once there is a second owner' do
      only = create(:tenant_membership, :owner, tenant: tenant, user: developer)

      expect { delete admin_tenant_membership_path(tenant, only) }.not_to change(TenantMembership, :count)
      expect(flash[:alert]).to include(developer.email)
      patch admin_tenant_membership_path(tenant, only), params: { role: 'member' }
      expect(only.reload.role).to eq('owner')

      create(:tenant_membership, :owner, tenant: tenant)
      patch admin_tenant_membership_path(tenant, only), params: { role: 'member' }
      expect(only.reload.role).to eq('member')
    end

    it 'answers 404 for another tenant\'s membership id' do
      other = create(:tenant_membership, tenant: create(:tenant, tenant_id: 'globex'), user: developer)

      expect { delete admin_tenant_membership_path(tenant, other) }.not_to change(TenantMembership, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  context 'as a non-admin' do
    it 'refuses a developer and creates nothing' do
      sign_in developer

      expect { post admin_tenant_memberships_path(tenant), params: { email: developer.email } }
        .not_to change(TenantMembership, :count)
      expect(response).not_to redirect_to(edit_admin_tenant_path(tenant))
    end
  end

  context 'as an admin who is a member of the tenant, on the tenant\'s own host' do
    it 'does not let a tenant\'s own admin add members (platform work stays on the default host)' do
      TenantMembership.create!(user: admin, tenant: tenant, role: 'owner')
      sign_in admin
      host! 'store.acme.example.com'
      developer

      expect { post admin_tenant_memberships_path(tenant), params: { email: developer.email } }
        .not_to change(TenantMembership, :count)
    end
  end
end
