# frozen_string_literal: true

require 'rails_helper'

# Task 45c: GET/POST /api/apps/:app_id/migrated_comments and DELETE .../:id (platform admin, user token only).
# Written by imitating api_app_migrated_stats_spec.rb; NOT run (no Ruby or database in the sandbox that wrote it).
RSpec.describe 'API app migrated_comments', type: :request do
  let(:password) { 'correct-horse-9' }
  let!(:app) { create(:app, name: 'Carry App') }
  let(:path) { "/api/apps/#{app.id}/migrated_comments" }
  let(:note) { 'Comments left on the old distribution page, copied by hand, Sept to Oct 2026' }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }
  let(:comments) do
    [{ author_name: 'Amina K.', rating: 5, body: 'Picked the right APK first time.', commented_on: '2026-09-02', helpful_count: 41 },
     { author_name: 'Zainab L.', rating: 3, body: 'Great idea, but search is slow.', commented_on: '2026-09-18', helpful_count: 23 }]
  end

  before { Zealot::TenantRegistry.reset! }

  it 'refuses a request with no credential and a non-admin user' do
    post path, params: { source_note: note, comments: comments }
    expect(response).to have_http_status(:unauthorized)

    post path, params: { token: developer.token, source_note: note, comments: comments }
    expect(response).to have_http_status(:forbidden)
    expect(MigratedComment.count).to eq(0)
  end

  it 'adds each comment as its own row, with the shared note and who entered it' do
    post path, params: { token: admin.token, source_note: note, comments: comments }

    expect(response).to have_http_status(:created)
    expect(app.migrated_comments.order(:commented_on).pluck(:author_name, :rating, :helpful_count))
      .to eq([['Amina K.', 5, 41], ['Zainab L.', 3, 23]])
    expect(app.migrated_comments.pluck(:source_note).uniq).to eq([note])
    expect(app.migrated_comments.pluck(:recorded_by_id).uniq).to eq([admin.id])
  end

  it 'saves nothing when one comment is invalid, and names the row' do
    bad = comments + [{ author_name: 'Nobody', rating: 9, commented_on: '2026-10-01' }]
    post path, params: { token: admin.token, source_note: note, comments: bad }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to start_with('comment 3:')
    expect(MigratedComment.count).to eq(0)
  end

  it 'refuses comments with no source note anywhere' do
    post path, params: { token: admin.token, comments: comments }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(MigratedComment.count).to eq(0)
  end

  it 'lists oldest first and deletes one comment' do
    post path, params: { token: admin.token, source_note: note, comments: comments.reverse }
    get path, params: { token: admin.token }
    expect(response.parsed_body['comments'].map { |c| c['author_name'] }).to eq(['Amina K.', 'Zainab L.'])

    delete "#{path}/#{app.migrated_comments.first.id}", params: { token: admin.token }
    expect(response).to have_http_status(:no_content)
    expect(app.migrated_comments.count).to eq(1)
  end
end
