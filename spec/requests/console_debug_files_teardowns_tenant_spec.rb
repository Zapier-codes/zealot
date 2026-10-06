# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-4b: debug files and teardowns read through the policy scope. Default host:
# everything, as before. A tenant's host: a non-member is refused, a member sees only that
# tenant's apps' files and releases' teardowns, another tenant's id is "not found", and a file
# cannot be placed on another tenant's app. Imitates console_apps_dashboard_tenant_spec.rb; NOT run
# in the sandbox that wrote it (no Rails boot or database there), so look here first if CI is red.
RSpec.describe 'Console debug files and teardowns and tenants', type: :request do
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

  def make_debug_file(app)
    DebugFile.new(app: app, device_type: 'Android', release_version: '1.0', build_version: '1')
             .tap { |file| file.save!(validate: false) }
  end

  def make_teardown(release, name)
    Metadatum.new(release: release, user: admin, name: name, device: 'Android', platform: 'android',
                  checksum: SecureRandom.hex(8)).tap { |md| md.save!(validate: false) }
  end

  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
  let!(:globex_app) { create(:app, name: 'Globex App', tenant: globex) }
  let!(:default_file) { make_debug_file(default_app) }
  let!(:acme_file) { make_debug_file(acme_app) }
  let!(:globex_file) { make_debug_file(globex_app) }
  let!(:default_teardown) { make_teardown(make_release(default_app), 'Default Teardown') }
  let!(:acme_teardown) { make_teardown(make_release(acme_app), 'Acme Teardown') }
  let!(:globex_teardown) { make_teardown(make_release(globex_app), 'Globex Teardown') }

  before do
    Zealot::TenantRegistry.reset!
    sign_in admin
  end

  context 'on the default host' do
    it 'lists every app\'s debug files and every teardown (unchanged)' do
      get debug_files_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')

      get teardowns_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Default Teardown', 'Acme Teardown', 'Globex Teardown')

      get debug_file_path(acme_file)
      expect(response).to have_http_status(:ok)
      get teardown_path(acme_teardown)
      expect(response).to have_http_status(:ok)
    end
  end

  context 'on a tenant host, as an admin who is not a member' do
    before { host! 'store.acme.example.com' }

    it 'refuses both lists (403)' do
      get debug_files_path
      expect(response).to have_http_status(:forbidden)

      get teardowns_path
      expect(response).to have_http_status(:forbidden)
    end

    it 'does not find the tenant\'s own file or teardown by id' do
      get debug_file_path(acme_file)
      expect(response).to have_http_status(:not_found)

      get teardown_path(acme_teardown)
      expect(response).to have_http_status(:not_found)
    end
  end

  context 'on a tenant host, as a member' do
    before do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'
    end

    it 'lists only the tenant\'s own apps\' debug files' do
      get debug_files_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
      expect(response.body).not_to include('Globex App')
    end

    it 'lists only the tenant\'s own teardowns' do
      get teardowns_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Acme Teardown')
      expect(response.body).not_to include('Default Teardown')
      expect(response.body).not_to include('Globex Teardown')
    end

    it 'opens its own file and teardown, and answers 404 for another tenant\'s or the default catalog\'s' do
      get debug_file_path(acme_file)
      expect(response).to have_http_status(:ok)
      get teardown_path(acme_teardown)
      expect(response).to have_http_status(:ok)

      [globex_file, default_file].each do |other|
        get debug_file_path(other)
        expect(response).to have_http_status(:not_found)
      end
      [globex_teardown, default_teardown].each do |other|
        get teardown_path(other)
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'cannot delete another tenant\'s file or teardown' do
      expect { delete debug_file_path(globex_file) }.not_to change(DebugFile, :count)
      expect { delete teardown_path(globex_teardown) }.not_to change(Metadatum, :count)
    end

    it 'cannot open the device list, or place a file, on another tenant\'s app' do
      get device_app_debug_files_path(globex_app, 'Android')
      expect(response).to have_http_status(:not_found)

      expect do
        post debug_files_path,
             params: { debug_file: { app_id: globex_app.id, device_type: 'Android', release_version: '1',
                                     build_version: '1' } }
      end.not_to change(DebugFile, :count)
    end
  end
end
