# frozen_string_literal: true

require 'rails_helper'

# Task 46c: POST /api/releases/:id/supersede_previous (user token; whoever may destroy the release). The service is
# stubbed, so nothing is deleted here; its own rules are in spec/services/release_superseder_spec.rb. Written by
# imitating api_release_rename_stored_spec.rb; NOT run (no Ruby in the sandbox that wrote it).
RSpec.describe 'API release supersede_previous', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Supersede App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 2, changelog: [], release_version: '1.1.0', build_version: '2')
           .tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/releases/#{release.id}/supersede_previous" }
  let(:superseder) { instance_double(ReleaseSuperseder) }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before do
    Zealot::TenantRegistry.reset!
    allow(ReleaseSuperseder).to receive(:new).with(release).and_return(superseder)
  end

  it 'refuses a request with no credential' do
    post path

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a user who may not manage the app' do
    allow(superseder).to receive(:call)

    post path, params: { token: developer.token }

    expect(response).to have_http_status(:forbidden)
    expect(superseder).not_to have_received(:call)
  end

  it 'answers 200 with what was removed' do
    entry = ReleaseSuperseder::Entry.new(id: 1, release_version: '1.0.0', build_version: '1')
    result = ReleaseSuperseder::Result.new(kept_id: release.id, dry_run: false, removed: [entry], failed: [])
    allow(superseder).to receive(:call).with(dry_run: false).and_return(result)

    post path, params: { token: admin.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => release.id, 'kept' => release.id, 'dry_run' => false)
    expect(response.parsed_body['removed']).to eq(
      [{ 'id' => 1, 'release_version' => '1.0.0', 'build_version' => '1' }]
    )
  end

  it 'passes dry_run through' do
    result = ReleaseSuperseder::Result.new(kept_id: release.id, dry_run: true, removed: [], failed: [])
    allow(superseder).to receive(:call).with(dry_run: true).and_return(result)

    post path, params: { token: admin.token, dry_run: 'true' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['dry_run']).to eq(true)
  end

  it 'answers 422 naming the reason when the service refuses' do
    allow(superseder).to receive(:call).and_raise(ReleaseSuperseder::Refused, 'not_installable')

    post path, params: { token: admin.token }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('cannot be installed yet')
  end

  it 'answers 404 for an unknown release id' do
    post '/api/releases/0/supersede_previous', params: { token: admin.token }

    expect(response).to have_http_status(:not_found)
  end
end
