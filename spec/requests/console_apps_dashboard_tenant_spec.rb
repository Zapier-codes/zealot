# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-4a: the apps list, the app lookup and the dashboard read through the policy
# scope. Default host: everything, as before. A tenant's host: a non-member is refused, a member
# sees only that tenant's apps and totals, another tenant's app id is "not found", and the
# platform-wide admin figures are not shown. Written by imitating admin_lists_tenant_spec.rb;
# NOT run in the sandbox that wrote it (no Rails boot or database there), so it is the first thing
# to look at if CI is red for this slice.
RSpec.describe 'Console apps list and dashboard and tenants', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:globex) { create(:tenant, tenant_id: 'globex', domains: ['store.globex.example.com']) }

  def make_release(app)
    scheme = app.schemes.create!(name: 'Main')
    channel = scheme.channels.create!(name: 'Android', device_type: :android)
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                build_version: '1').tap { |release| release.save!(validate: false) }
  end

  # The four general dashboard widgets, in page order: apps, debug files, teardowns, uploads.
  def widget_values
    response.body.scan(/d-stat-value[^>]*>\s*(?:<a[^>]*>)?\s*(\d+|-)\s*</).flatten.first(4)
  end

  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
  let!(:globex_app) { create(:app, name: 'Globex App', tenant: globex) }

  before do
    Zealot::TenantRegistry.reset!
    sign_in admin
  end

  context 'on the default host' do
    it 'lists every app, tenants\' included (unchanged), and finds any app by id' do
      get apps_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')

      get app_path(acme_app)
      expect(response).to have_http_status(:ok)
    end

    it 'counts every app and every release on the dashboard, and shows the admin figures' do
      make_release(default_app)
      make_release(acme_app)

      get dashboard_path

      expect(response).to have_http_status(:ok)
      expect(widget_values.first).to eq('3')
      expect(widget_values.last).to eq('2')
      expect(response.body).to include(admin_users_path)
    end
  end

  context 'on a tenant host, as an admin who is not a member' do
    before { host! 'store.acme.example.com' }

    it 'refuses the apps list and the dashboard (403), not an empty page' do
      get apps_path
      expect(response).to have_http_status(:forbidden)

      get dashboard_path
      expect(response).to have_http_status(:forbidden)
    end

    it 'does not find the tenant\'s own app by id' do
      get app_path(acme_app)

      expect(response).not_to have_http_status(:ok)
      expect(response.body).not_to include('Acme App')
    end
  end

  context 'on a tenant host, as a member' do
    before do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'
    end

    it 'lists only the tenant\'s own apps' do
      get apps_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
      expect(response.body).not_to include('Globex App')
    end

    it 'finds its own app, and treats another tenant\'s or the default catalog\'s id as not found' do
      get app_path(acme_app)
      expect(response).to have_http_status(:ok)

      [globex_app, default_app].each do |other|
        get app_path(other)
        expect(response).not_to have_http_status(:ok)
        expect(response.body).not_to include(other.name)
      end
    end

    it 'cannot edit or delete another tenant\'s app by id' do
      get edit_app_path(globex_app)
      expect(response).not_to have_http_status(:ok)

      expect { delete app_path(globex_app) }.not_to change(App, :count)
    end

    it 'counts only the tenant\'s apps and releases on the dashboard' do
      make_release(default_app)
      make_release(acme_app)
      make_release(globex_app)

      get dashboard_path

      expect(response).to have_http_status(:ok)
      expect(widget_values.first).to eq('1')
      expect(widget_values.last).to eq('1')
    end

    it 'does not show the platform-wide figures (users, webhooks, jobs, disk) to a tenant\'s admin' do
      get dashboard_path

      expect(response.body).not_to include(admin_users_path)
      expect(response.body).not_to include(admin_web_hooks_path)
    end
  end
end
