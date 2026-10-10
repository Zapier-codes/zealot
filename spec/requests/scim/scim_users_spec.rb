# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SCIM half; Play Console parity): the /scim/v2 endpoints an identity provider's provisioning client
# calls. Written by reading the controller, like the other slices' specs.
RSpec.describe 'SCIM provisioning', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:tenant) { create(:tenant, tenant_id: 'acme') }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let!(:issued) { ScimToken.issue!(tenant: tenant, name: 'okta', created_by: admin) }

  def auth(secret = issued.secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def json
    JSON.parse(response.body)
  end

  describe 'authentication' do
    it 'rejects a missing token' do
      get scim_users_path
      expect(response).to have_http_status(:unauthorized)
      expect(json['schemas']).to eq(['urn:ietf:params:scim:api:messages:2.0:Error'])
    end

    it 'rejects an unknown token' do
      get scim_users_path, headers: auth("#{ScimToken::PREFIX}#{'a' * 43}")
      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts a live token and stamps its last use' do
      get scim_users_path, headers: auth
      expect(response).to have_http_status(:ok)
      expect(issued.token.reload.last_used_at).to be_present
    end

    it 'rejects a revoked token' do
      issued.token.revoke!
      get scim_users_path, headers: auth
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /scim/v2/Users' do
    it 'lists only the token\'s tenant members and reports the total' do
      member = create(:user, email: 'ann@acme.example.com', username: 'ann')
      create(:tenant_membership, tenant: tenant, user: member)
      create(:user, email: 'outsider@other.example.com', username: 'outsider')

      get scim_users_path, headers: auth

      expect(response).to have_http_status(:ok)
      expect(json['totalResults']).to eq(1)
      expect(json['Resources'].first['userName']).to eq('ann@acme.example.com')
      expect(json['Resources'].first['active']).to be(true)
    end

    it 'filters by userName' do
      member = create(:user, email: 'ann@acme.example.com', username: 'ann')
      create(:tenant_membership, tenant: tenant, user: member)

      get scim_users_path, params: { filter: 'userName eq "ann@acme.example.com"' }, headers: auth

      expect(json['totalResults']).to eq(1)
    end

    it 'matches nothing for an unsupported filter' do
      member = create(:user, email: 'ann@acme.example.com', username: 'ann')
      create(:tenant_membership, tenant: tenant, user: member)

      get scim_users_path, params: { filter: 'foo sw "bar"' }, headers: auth

      expect(json['totalResults']).to eq(0)
    end
  end

  describe 'POST /scim/v2/Users' do
    it 'creates an SSO account and a membership, answering 201 with the resource' do
      expect do
        post scim_users_path, headers: auth, as: :json,
             params: { userName: 'new@acme.example.com', name: { givenName: 'New' } }
      end.to change(User, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(json['userName']).to eq('new@acme.example.com')
      expect(json['active']).to be(true)
      expect(TenantMembership.for_tenant(tenant).count).to eq(1)
    end

    it 'answers 400 on a missing userName' do
      post scim_users_path, headers: auth, as: :json, params: { name: { givenName: 'X' } }

      expect(response).to have_http_status(:bad_request)
      expect(json['scimType']).to eq('invalidValue')
    end
  end

  describe 'PATCH /scim/v2/Users/:id (update)' do
    let!(:member) { create(:user, email: 'ann@acme.example.com', username: 'ann') }
    let!(:membership) { create(:tenant_membership, tenant: tenant, user: member) }

    it 'de-provisions with active=false: membership gone, account locked, row kept' do
      expect do
        put scim_user_path(member), headers: auth, as: :json, params: { active: false }
      end.not_to change(User, :count)

      expect(response).to have_http_status(:ok)
      expect(json['active']).to be(false)
      expect(TenantMembership.for_tenant(tenant).where(user: member)).to be_empty
      expect(member.reload.access_locked?).to be(true)
    end

    it 'records an audit entry naming the token by its last four' do
      expect do
        put scim_user_path(member), headers: auth, as: :json, params: { active: false }
      end.to change(AuditEntry, :count).by(1)

      entry = AuditEntry.last
      expect(entry.action).to eq('updated')
      expect(entry.summary).to include(issued.token.last_four)
    end
  end

  describe 'DELETE /scim/v2/Users/:id' do
    it 'de-provisions and answers 204, idempotently' do
      member = create(:user, email: 'ann@acme.example.com', username: 'ann')
      create(:tenant_membership, tenant: tenant, user: member)

      delete scim_user_path(member), headers: auth
      expect(response).to have_http_status(:no_content)

      delete scim_user_path(member), headers: auth
      expect(response).to have_http_status(:no_content)
    end

    it 'answers 404 for a user outside the token\'s tenant' do
      outsider = create(:user, email: 'out@other.example.com', username: 'out')

      get scim_user_path(outsider), headers: auth
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'discovery documents' do
    it 'serves the ServiceProviderConfig' do
      get '/scim/v2/ServiceProviderConfig', headers: auth
      expect(response).to have_http_status(:ok)
      expect(json['patch']['supported']).to be(true)
      expect(json['authenticationSchemes'].first['type']).to eq('oauthbearertoken')
    end

    it 'serves Schemas and ResourceTypes' do
      get '/scim/v2/Schemas', headers: auth
      expect(response).to have_http_status(:ok)
      expect(json['Resources'].first['id']).to eq(Scim::UserMapper::USER_SCHEMA)

      get '/scim/v2/ResourceTypes', headers: auth
      expect(response).to have_http_status(:ok)
      expect(json['Resources'].first['endpoint']).to eq('/Users')
    end
  end
end
