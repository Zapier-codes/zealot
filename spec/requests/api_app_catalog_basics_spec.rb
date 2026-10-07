# frozen_string_literal: true

require 'rails_helper'

# Task 45f: GET/PUT /api/apps/:app_id/catalog_basics (platform admin, user token only). Written by imitating
# api_app_migrated_stats_spec.rb; NOT run (no Ruby or database in the sandbox that wrote it).
RSpec.describe 'API app catalog_basics', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Basics App') }
  let(:path) { "/api/apps/#{app.id}/catalog_basics" }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  before { Zealot::TenantRegistry.reset! }

  it 'refuses a request with no credential and a non-admin user' do
    put path, params: { category: 'entertainment' }
    expect(response).to have_http_status(:unauthorized)

    put path, params: { token: developer.token, category: 'entertainment' }
    expect(response).to have_http_status(:forbidden)
    expect(app.reload.category).to be_nil
  end

  it 'sets the category and the package name and answers the stored values' do
    put path, params: { token: admin.token, category: 'entertainment', package_name: 'com.vythera.vyxelapps' }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('category' => 'entertainment', 'package_name' => 'com.vythera.vyxelapps')
    expect(app.reload).to have_attributes(category: 'entertainment', play_package_name: 'com.vythera.vyxelapps')
  end

  it 'refuses an unknown category and a malformed package name, changing nothing' do
    put path, params: { token: admin.token, category: 'app_stores' }
    expect(response).to have_http_status(:unprocessable_entity)

    put path, params: { token: admin.token, package_name: 'not a package' }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.reload).to have_attributes(category: nil, play_package_name: nil)
  end

  it 'clears a field with an empty value and refuses a call that sends nothing' do
    app.update!(category: 'tools')
    put path, params: { token: admin.token, category: '' }
    expect(app.reload.category).to be_nil

    put path, params: { token: admin.token }
    expect(response).to have_http_status(:unprocessable_entity)
  end
end
