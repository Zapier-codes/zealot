# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-5: `/api` reads apps, collaborators, schemes and channels through the policy
# scope. Default host: everything, as before. A tenant's host: a non-member is refused the list
# (403), a member sees only that tenant's apps, and another tenant's (or the default catalog's)
# id is a plain 404. Written by imitating console_apps_dashboard_tenant_spec.rb; NOT run in the
# sandbox that wrote it (no Rails boot or database there), so it is the first thing to look at if
# CI is red for this slice.
RSpec.describe 'API and tenants', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:globex) { create(:tenant, tenant_id: 'globex', domains: ['store.globex.example.com']) }

  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
  let!(:globex_app) { create(:app, name: 'Globex App', tenant: globex) }

  def make_channel(app)
    scheme = app.schemes.create!(name: "Scheme #{app.name}")
    channel = scheme.channels.create!(name: "Channel #{app.name}", device_type: :android)
    [scheme, channel]
  end

  def api_get(path, **params)
    get path, params: { token: admin.token }.merge(params)
  end

  before { Zealot::TenantRegistry.reset! }

  context 'on the default host' do
    it 'lists every app, tenants\' included (unchanged), and finds any app, scheme and channel' do
      _scheme, channel = make_channel(acme_app)

      api_get api_apps_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')

      api_get api_app_path(acme_app)
      expect(response).to have_http_status(:ok)

      api_get api_channel_path(channel)
      expect(response).to have_http_status(:ok)
    end
  end

  context 'on a tenant host, as an admin who is not a member' do
    before { host! 'store.acme.example.com' }

    it 'refuses the app list (403)' do
      api_get api_apps_path
      expect(response).to have_http_status(:forbidden)
    end

    it 'does not find the tenant\'s own app by id (404)' do
      api_get api_app_path(acme_app)
      expect(response).to have_http_status(:not_found)
    end
  end

  context 'on a tenant host, as a member' do
    before do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'
    end

    it 'lists only the tenant\'s own apps, in every scope' do
      [{}, { scope: 'active' }, { scope: 'archived' }].each do |params|
        api_get api_apps_path, **params
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Default App')
        expect(response.body).not_to include('Globex App')
      end

      api_get api_apps_path
      expect(response.body).to include('Acme App')
    end

    it 'finds its own app, and answers 404 for another tenant\'s or the default catalog\'s id' do
      api_get api_app_path(acme_app)
      expect(response).to have_http_status(:ok)

      [globex_app, default_app].each do |other|
        api_get api_app_path(other)
        expect(response).to have_http_status(:not_found)
        expect(response.body).not_to include(other.name)
      end
    end

    it 'cannot edit or delete another tenant\'s app by id' do
      put api_app_path(globex_app), params: { token: admin.token, name: 'Hijacked' }
      expect(response).to have_http_status(:not_found)
      expect(globex_app.reload.name).to eq('Globex App')

      expect { delete api_app_path(globex_app), params: { token: admin.token } }.not_to change(App, :count)
    end

    it 'reads schemes and channels of its own app, and answers 404 for another tenant\'s' do
      own_scheme, own_channel = make_channel(acme_app)
      other_scheme, other_channel = make_channel(globex_app)

      api_get api_app_schemes_path(acme_app)
      expect(response).to have_http_status(:ok)
      api_get api_scheme_path(own_scheme)
      expect(response).to have_http_status(:ok)
      api_get api_channel_path(own_channel)
      expect(response).to have_http_status(:ok)

      api_get api_app_schemes_path(globex_app)
      expect(response).to have_http_status(:not_found)
      api_get api_scheme_path(other_scheme)
      expect(response).to have_http_status(:not_found)
      api_get api_scheme_channels_path(other_scheme)
      expect(response).to have_http_status(:not_found)
      api_get api_channel_path(other_channel)
      expect(response).to have_http_status(:not_found)
    end

    it 'cannot create a scheme under another tenant\'s app' do
      expect do
        post api_app_schemes_path(globex_app), params: { token: admin.token, name: 'Sneaky' }
      end.not_to change(Scheme, :count)
      expect(response).to have_http_status(:not_found)
    end

    it 'answers 404 for another tenant\'s collaborator route' do
      api_get api_app_collaborator_path(globex_app, admin.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
