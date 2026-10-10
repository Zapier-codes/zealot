# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SCIM half; Play Console parity): the admin page that mints, lists and revokes SCIM tokens. Only a
# platform admin on the default host (ScimTokenPolicy). Written by imitating admin_audit_entries_spec.rb.
RSpec.describe 'Admin SCIM tokens', type: :request do
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

  before { Zealot::TenantRegistry.reset! }

  context 'as a platform admin on the default host' do
    before { sign_in admin }

    it 'lists the tokens, showing only the last four' do
      issued = ScimToken.issue!(tenant: nil, name: 'okta', created_by: admin)

      get admin_scim_tokens_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('okta')
      expect(response.body).to include(issued.token.last_four)
      expect(response.body).not_to include(issued.secret)
    end

    it 'mints a token and shows the secret exactly once, in the flash' do
      expect do
        post admin_scim_tokens_path, params: { scim_token: { name: 'okta' } }
      end.to change(ScimToken, :count).by(1)

      expect(response).to redirect_to(admin_scim_tokens_path)
      expect(flash[:notice]).to match(ScimToken::SECRET_FORMAT)
    end

    it 'records an audit entry when a token is minted' do
      expect do
        post admin_scim_tokens_path, params: { scim_token: { name: 'okta' } }
      end.to change(AuditEntry, :count).by(1)

      expect(AuditEntry.last.action).to eq('created')
    end

    it 'rejects a blank name' do
      expect do
        post admin_scim_tokens_path, params: { scim_token: { name: '' } }
      end.not_to change(ScimToken, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'revokes a token, softly' do
      issued = ScimToken.issue!(tenant: nil, name: 'okta', created_by: admin)

      expect do
        delete admin_scim_token_path(issued.token)
      end.not_to change(ScimToken, :count)

      expect(issued.token.reload.revoked_at).to be_present
      expect(response).to redirect_to(admin_scim_tokens_path)
    end
  end

  context 'as a non-admin' do
    before { sign_in developer }

    it 'is forbidden' do
      get admin_scim_tokens_path
      expect(response).not_to have_http_status(:ok)
    end
  end

  describe 'the SAML panel' do
    before { sign_in admin }

    it 'reports SAML as not ready when the config is incomplete' do
      previous = Setting.saml
      Setting.saml = {}

      get admin_saml_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t('admin.saml_settings.show.not_configured'))
    ensure
      Setting.saml = previous
    end

    it 'serves the SP metadata XML' do
      get metadata_admin_saml_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('EntityDescriptor')
      expect(response.media_type).to eq('application/samlmetadata+xml')
    end
  end
end
