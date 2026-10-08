# frozen_string_literal: true

require 'rails_helper'

# Task 46b: PUT /api/releases/:id/permissions (user token; whoever may update the release). Written by imitating
# api_release_rename_stored_spec.rb; NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe 'API release permissions', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Permissions App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.0', build_version: '1')
           .tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/releases/#{release.id}/permissions" }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before { Zealot::TenantRegistry.reset! }

  it 'refuses a request with no credential' do
    put path, params: { permissions: ['android.permission.INTERNET'] }

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a user who may not manage the app' do
    put path, params: { token: developer.token, permissions: ['android.permission.INTERNET'] }

    expect(response).to have_http_status(:forbidden)
    expect(release.reload.permissions).to eq([])
  end

  it 'stores the list sorted and without duplicates' do
    put path, params: { token: admin.token,
                        permissions: ['android.permission.WAKE_LOCK', 'android.permission.INTERNET',
                                      'android.permission.INTERNET'] }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['permissions']).to eq(%w[android.permission.INTERNET android.permission.WAKE_LOCK])
    expect(release.reload.permissions).to eq(%w[android.permission.INTERNET android.permission.WAKE_LOCK])
  end

  it 'accepts one string separated by commas' do
    put path, params: { token: admin.token,
                        permissions: 'android.permission.INTERNET, android.permission.CAMERA' }

    expect(response).to have_http_status(:ok)
    expect(release.reload.permissions).to eq(%w[android.permission.CAMERA android.permission.INTERNET])
  end

  it 'reports the names it dropped instead of hiding them' do
    put path, params: { token: admin.token, permissions: ['android.permission.INTERNET', 'not a permission!'] }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['permissions']).to eq(['android.permission.INTERNET'])
    expect(response.parsed_body['ignored']).to eq(['not a permission!'])
  end

  it 'clears the list when an empty array is sent' do
    release.update_columns(permissions: ['android.permission.INTERNET'])

    put path, params: { token: admin.token, permissions: [] }, as: :json

    expect(response).to have_http_status(:ok)
    expect(release.reload.permissions).to eq([])
  end

  it 'answers 422 when permissions is not sent at all' do
    put path, params: { token: admin.token }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('permissions')
  end

  it 'answers 422 for an archived app and changes nothing' do
    app.update!(archived: true)

    put path, params: { token: admin.token, permissions: ['android.permission.INTERNET'] }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(release.reload.permissions).to eq([])
  end

  it 'republishes the catalog index of a live app' do
    allow_any_instance_of(App).to receive(:listing_live?).and_return(true)
    allow(CatalogIndexPublishJob).to receive(:enqueue_for)

    put path, params: { token: admin.token, permissions: ['android.permission.INTERNET'] }

    expect(CatalogIndexPublishJob).to have_received(:enqueue_for).at_least(:once)
  end

  it 'watches permissions as a catalog index field' do
    expect(Release::CATALOG_INDEX_RELEASE_FIELDS).to include('permissions')
  end

  it 'answers 404 for an unknown release id' do
    put '/api/releases/0/permissions', params: { token: admin.token, permissions: [] }, as: :json

    expect(response).to have_http_status(:not_found)
  end
end
