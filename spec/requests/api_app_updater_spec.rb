# frozen_string_literal: true

require 'rails_helper'

# Task 47e: GET/PUT /api/apps/:app_id/updater (the publisher's switch for the injected updater). Written by
# imitating api_app_catalog_basics_spec.rb; NOT run (no Postgres or gems in the sandbox that wrote it).
RSpec.describe 'API app updater switch', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Updater App') }
  let(:path) { "/api/apps/#{app.id}/updater" }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:stranger) { make_user('stranger@example.com', :developer) }

  before { Zealot::TenantRegistry.reset! }

  it 'defaults to on' do
    expect(app.updater_enabled).to be(true)

    get path, params: { token: admin.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq('app_id' => app.id, 'enabled' => true)
  end

  it 'refuses a request with no credential' do
    put path, params: { enabled: 'false' }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload.updater_enabled).to be(true)
  end

  it 'refuses a user who may not update the app' do
    put path, params: { token: stranger.token, enabled: 'false' }

    expect(response).to have_http_status(:forbidden)
    expect(app.reload.updater_enabled).to be(true)
  end

  it 'turns it off and on again, repeating harmlessly' do
    2.times do
      put path, params: { token: admin.token, enabled: 'false' }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include('enabled' => false)
    end
    expect(app.reload.updater_enabled).to be(false)

    put path, params: { token: admin.token, enabled: 'true' }
    expect(response.parsed_body).to include('enabled' => true)
    expect(app.reload.updater_enabled).to be(true)
  end

  it 'refuses a missing or unrecognised value, changing nothing' do
    put path, params: { token: admin.token }
    expect(response).to have_http_status(:unprocessable_entity)

    put path, params: { token: admin.token, enabled: 'maybe' }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload.updater_enabled).to be(true)
  end
end
