# frozen_string_literal: true

require 'rails_helper'

# Task 40q: POST /api/releases/:id/retry_compile re-sends a release to CI (platform admin, user token only).
# Written by imitating api_release_release_spec.rb and api_android_signing_key_spec.rb; NOT run (no Ruby or
# database in the sandbox that wrote it), so look here first if CI is red for this slice. The job is stubbed
# at `perform_later`, so no GitHub call is made.
RSpec.describe 'API release retry_compile', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Retry App') }
  let!(:channel) do
    app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android)
  end
  let(:state) { 'failed' }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.0', build_version: '1',
                ci_compile_state: state, ci_compile_error: 'old reason', file_storage_key: 'uploads/r1/app.aab')
           .tap { |r| r.save!(validate: false) }
  end
  let(:path) { "/api/releases/#{release.id}/retry_compile" }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  # This door is the legacy user-token one (Api::BaseController#validate_user_token): it reads params[:token].
  def as(user)
    { token: user.token }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before do
    Zealot::TenantRegistry.reset!
    stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'true'))
    allow(CiCompileDispatchJob).to receive(:perform_later)
  end

  it 'refuses a request with no credential' do
    post path

    expect(response).to have_http_status(:unprocessable_entity)
    expect(release.reload.ci_compile_state).to eq('failed')
  end

  it 'refuses a non-admin user' do
    post path, params: as(developer)

    expect(response).to have_http_status(:forbidden)
    expect(release.reload.ci_compile_state).to eq('failed')
    expect(CiCompileDispatchJob).not_to have_received(:perform_later)
  end

  it 'queues a failed AAB release for CI again and clears the old error' do
    post path, params: as(admin)

    expect(response).to have_http_status(:accepted)
    expect(response.parsed_body).to include('id' => release.id, 'ci_compile_state' => 'queued')
    expect(release.reload).to have_attributes(ci_compile_state: 'queued', ci_compile_error: nil)
    expect(CiCompileDispatchJob).to have_received(:perform_later).with(release.id)
  end

  context 'when the release is already dispatched' do
    let(:state) { 'dispatched' }

    it 'answers 422 naming the state and changes nothing' do
      post path, params: as(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['ci_compile_state']).to eq('dispatched')
      expect(CiCompileDispatchJob).not_to have_received(:perform_later)
    end
  end

  context 'when CI is switched off' do
    before { stub_const('ENV', ENV.to_hash.merge('CI_COMPILE_ENABLED' => 'false')) }

    it 'answers 422 and does not queue' do
      post path, params: as(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(release.reload.ci_compile_state).to eq('failed')
    end
  end

  it 'answers 404 for an unknown release id' do
    post '/api/releases/0/retry_compile', params: as(admin)

    expect(response).to have_http_status(:not_found)
  end
end
