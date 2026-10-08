# frozen_string_literal: true

require 'rails_helper'

# Task 45a: PUT/GET /api/apps/:app_id/migrated_stats (platform admin, user token only). Written by imitating
# api_release_retry_compile_spec.rb; NOT run (no Ruby or database in the sandbox that wrote it).
RSpec.describe 'API app migrated_stats', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Carry App') }
  let(:path) { "/api/apps/#{app.id}/migrated_stats" }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before { Zealot::TenantRegistry.reset! }

  it 'refuses a request with no credential and a non-admin user' do
    put path, params: { downloads: 100, source_note: 'x' }
    expect(response).to have_http_status(:unprocessable_entity)

    put path, params: { token: developer.token, downloads: 100, source_note: 'x' }
    expect(response).to have_http_status(:forbidden)
    expect(app.reload.migrated_downloads).to eq(0)
  end

  it 'sets downloads and ratings, records who and when, and answers the stored figures' do
    put path, params: { token: admin.token, downloads: 12_400, rating_average: 4.3, rating_count: 380,
                        source_note: 'Direct APK downloads counted by the distribution server, 2024 to 2026' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('downloads' => 12_400, 'rating_average' => 4.3, 'rating_count' => 380,
                                            'recorded_by_id' => admin.id)
    expect(app.reload).to have_attributes(migrated_downloads: 12_400, migrated_rating_count: 380,
                                          migrated_recorded_by_id: admin.id)
  end

  it 'refuses figures without a source note' do
    put path, params: { token: admin.token, downloads: 500 }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload.migrated_downloads).to eq(0)
  end

  it 'refuses an average outside 1 to 5 and an average with no count' do
    put path, params: { token: admin.token, rating_average: 6, rating_count: 10, source_note: 'x' }
    expect(response).to have_http_status(:unprocessable_entity)

    put path, params: { token: admin.token, rating_average: 4, rating_count: 0, source_note: 'x' }
    expect(response).to have_http_status(:ok) # a count of 0 clears the average
    expect(app.reload.migrated_rating_average).to be_nil
  end

  it 'answers 422 when nothing is sent' do
    put path, params: { token: admin.token }

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'reads the stored figures back for an admin' do
    app.update!(migrated_downloads: 7, migrated_source_note: 'note')

    get path, params: { token: admin.token }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('downloads' => 7, 'source_note' => 'note')
  end
end
