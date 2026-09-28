# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-5b: `/api` releases and debug files, addressed by id, read through the policy
# scope. Default host: any id, as before. A tenant's host: a member reaches only that tenant's
# apps' releases and files; another tenant's (or the default catalog's) id is a plain 404, and a
# non-member gets 404 too (nothing is in scope for them). Imitates api_tenant_spec.rb; NOT run in
# the sandbox that wrote it (no Rails boot or database there), so look here first if CI is red.
RSpec.describe 'API releases and debug files and tenants', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:globex) { create(:tenant, tenant_id: 'globex', domains: ['store.globex.example.com']) }

  def make_release(app)
    scheme = app.schemes.create!(name: "Scheme #{app.name}")
    channel = scheme.channels.create!(name: "Channel #{app.name}", device_type: :android)
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                build_version: '1').tap { |release| release.save!(validate: false) }
  end

  def make_debug_file(app)
    DebugFile.new(app: app, device_type: 'Android', release_version: '1.0', build_version: '1')
             .tap { |file| file.save!(validate: false) }
  end

  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
  let!(:globex_app) { create(:app, name: 'Globex App', tenant: globex) }
  let!(:default_release) { make_release(default_app) }
  let!(:acme_release) { make_release(acme_app) }
  let!(:globex_release) { make_release(globex_app) }
  let!(:default_file) { make_debug_file(default_app) }
  let!(:acme_file) { make_debug_file(acme_app) }
  let!(:globex_file) { make_debug_file(globex_app) }

  before { Zealot::TenantRegistry.reset! }

  context 'on the default host' do
    it 'edits and deletes any release by id, tenant-owned included (unchanged)' do
      put api_release_path(acme_release), params: { token: admin.token, changelog: 'x' }
      expect(response).to have_http_status(:ok)

      expect { delete api_release_path(globex_release), params: { token: admin.token } }
        .to change(Release, :count).by(-1)
      expect(response).to have_http_status(:ok)
    end

    it 'reads any debug file by id, tenant-owned included (unchanged)' do
      [default_file, acme_file, globex_file].each do |file|
        get api_debug_file_path(file), params: { token: admin.token }
        expect(response).to have_http_status(:ok)
      end
    end
  end

  context 'on a tenant host, as an admin who is not a member' do
    before { host! 'store.acme.example.com' }

    it 'finds neither the tenant\'s own release nor its debug file (404)' do
      put api_release_path(acme_release), params: { token: admin.token, changelog: 'x' }
      expect(response).to have_http_status(:not_found)

      get api_debug_file_path(acme_file), params: { token: admin.token }
      expect(response).to have_http_status(:not_found)
    end
  end

  context 'on a tenant host, as a member' do
    before do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'
    end

    it 'edits its own release and reads its own debug file' do
      put api_release_path(acme_release), params: { token: admin.token, changelog: 'x' }
      expect(response).to have_http_status(:ok)

      get api_debug_file_path(acme_file), params: { token: admin.token }
      expect(response).to have_http_status(:ok)
    end

    it 'cannot edit or delete another tenant\'s or the default catalog\'s release (404)' do
      [globex_release, default_release].each do |release|
        put api_release_path(release), params: { token: admin.token, changelog: 'x' }
        expect(response).to have_http_status(:not_found)
      end

      expect { delete api_release_path(globex_release), params: { token: admin.token } }
        .not_to change(Release, :count)
      expect(response).to have_http_status(:not_found)
    end

    it 'cannot read another tenant\'s or the default catalog\'s debug file (404)' do
      [globex_file, default_file].each do |file|
        get api_debug_file_path(file), params: { token: admin.token }
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'cannot update or delete another tenant\'s debug file (404, and nothing is deleted)' do
      expect { delete api_debug_file_path(globex_file), params: { token: admin.token } }
        .not_to change(DebugFile, :count)
      expect(response).to have_http_status(:not_found)

      put api_debug_file_path(globex_file), params: { token: admin.token, release_version: '9' }
      expect(response).to have_http_status(:not_found)
    end
  end
end
