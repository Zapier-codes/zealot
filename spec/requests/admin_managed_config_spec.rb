# frozen_string_literal: true

require 'rails_helper'

# Z-P24 (enterprise device management): the read-only managed-configuration panel and the
# `managed-config.json` document a DPC's provisioning tooling reads. Platform admins only (ManagedConfigPolicy).
RSpec.describe 'Admin managed configuration', type: :request do
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

  context 'as a platform admin' do
    before { sign_in admin }

    it 'reports an unmanaged store and publishes no document' do
      Setting.managed_config = {}

      get admin_managed_config_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('unmanaged')
    end

    it 'shows the set keys and serves the exact documented JSON' do
      Setting.managed_config = { 'enabled_sources' => 'fdroid', 'hidden_packages' => 'com.secret' }

      get admin_managed_config_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('enabled_sources')

      get download_admin_managed_config_path
      expect(response).to have_http_status(:ok)
      doc = JSON.parse(response.body)
      expect(doc['managed_keys']).to contain_exactly('enabled_sources', 'hidden_packages')
      expect(doc['config']['enabled_sources']).to eq(['FDroid'])
      expect(JSON.parse(response.body)['config']['hidden_packages']).to eq(['com.secret'])
    end
  end

  context 'as a non-admin' do
    before { sign_in developer }

    it 'is refused the panel and the document' do
      get admin_managed_config_path
      expect(response).not_to have_http_status(:ok)

      get download_admin_managed_config_path
      expect(response).not_to have_http_status(:ok)
    end
  end
end
