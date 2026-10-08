# frozen_string_literal: true

require 'rails_helper'

# Task 44f: POST /api/releases/:id/rename_stored (platform admin, user token only). The renamer is stubbed, so no
# storage is touched. Written by imitating api_release_retry_compile_spec.rb; NOT run (no Ruby in the sandbox).
RSpec.describe 'API release rename_stored', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Rename App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.0', build_version: '1',
                file_storage_key: 'uploads/apps/a1/r1/binary/app.aab').tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/releases/#{release.id}/rename_stored" }
  let(:renamer) { instance_double(ReleaseStoredRenamer) }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  def as(user)
    { token: user.token }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before do
    Zealot::TenantRegistry.reset!
    allow(ReleaseStoredRenamer).to receive(:new).and_return(renamer)
  end

  it 'refuses a request with no credential' do
    post path

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a non-admin user' do
    allow(renamer).to receive(:call)

    post path, params: as(developer)

    expect(response).to have_http_status(:forbidden)
    expect(renamer).not_to have_received(:call)
  end

  it 'answers 200 with what moved' do
    change = ReleaseStoredRenamer::Change.new(column: :universal_apk_storage_key, from: 'a/universal.apk',
                                              to: 'a/appstore-1.0.0.apk', status: :renamed)
    allow(renamer).to receive(:call).and_return([change])

    post path, params: as(admin)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['changes']).to eq(
      [{ 'column' => 'universal_apk_storage_key', 'from' => 'a/universal.apk', 'to' => 'a/appstore-1.0.0.apk',
         'status' => 'renamed' }]
    )
  end

  it 'answers 422 when the renamer refuses' do
    allow(renamer).to receive(:call).and_raise(ReleaseStoredRenamer::Refused, 'ci_busy')

    post path, params: as(admin)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('CI is still working')
  end

  it 'answers 502 naming what storage said' do
    allow(renamer).to receive(:call).and_raise(ReleaseStorage::StorageError, 'GitHub rename failed: HTTP 422')

    post path, params: as(admin)

    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body['error']).to include('HTTP 422')
  end

  it 'answers 404 for an unknown release id' do
    post '/api/releases/0/rename_stored', params: as(admin)

    expect(response).to have_http_status(:not_found)
  end
end
