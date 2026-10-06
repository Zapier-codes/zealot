# frozen_string_literal: true

require 'rails_helper'

# Task 40r: `POST /api/apps/upload_sessions` without a `channel_key` opens the FIRST upload of an app. Nothing is
# created at session time (the app, scheme and channel come at stage 1). Imitates release_upload_sessions_spec.rb;
# R2 is a fake. NOT run (no Rails or database in the sandbox that wrote it); look here first if CI is red.
RSpec.describe 'API upload session for a new app', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:role) { :developer }
  let!(:developer) do
    User.create!(email: 'dev@example.com', username: 'dev', password: password, password_confirmation: password,
                 confirmed_at: Time.current, role: role)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:channel) do
    app.schemes.create!(name: 'Scheme').channels.create!(name: 'Channel', device_type: :android)
  end
  let(:presigned) do
    ReleaseUploadStaging::Presigned.new(url: 'https://r2.example/put?sig=1', method: 'PUT', headers: {},
                                        expires_at: 2.hours.from_now)
  end
  let(:staging) do
    instance_double(ReleaseUploadStaging, presign_put: presigned, delete: true,
                                          head: ReleaseUploadStaging::Head.new(size: 5000, etag: 'e1'))
  end

  def open_session(headers: {}, **params)
    post '/api/apps/upload_sessions', params: { filename: 'app.apk', size: 5000 }.merge(params), headers: headers
  end

  before do
    Zealot::TenantRegistry.reset!
    allow(ReleaseUploadSession).to receive(:enabled?).and_return(true)
    allow(ReleaseUploadStaging).to receive(:new).and_return(staging)
  end

  it 'opens a channel-less session marked as a new app, and creates no app, scheme or channel' do
    before_counts = [App.count, Scheme.count, Channel.count]

    expect { open_session(token: developer.token, name: 'Brand New', slug: 'brand-new') }
      .to change(ReleaseUpload, :count).by(1)

    expect([App.count, Scheme.count, Channel.count]).to eq(before_counts)
    expect(response).to have_http_status(:created)
    row = ReleaseUpload.last
    expect(row.channel_id).to be_nil
    expect(row.form_options).to include('new_app' => true, 'name' => 'Brand New', 'slug' => 'brand-new',
                                        'source' => 'api')
    expect(row.staging_key).to start_with("staging/#{ReleaseUpload::NEW_APP_KEY_SEGMENT}/u#{row.id}/")
  end

  it 'never stores a channel password' do
    open_session(token: developer.token, password: 'secret-123')

    expect(ReleaseUpload.last.form_options.keys).not_to include('password')
  end

  it 'ignores the new-app options when a channel_key is sent' do
    open_session(token: developer.token, channel_key: channel.key, name: 'Ignored')

    row = ReleaseUpload.last
    expect(row.channel_id).to eq(channel.id)
    expect(row.form_options).not_to include('new_app', 'name')
  end

  context 'when the caller is a plain member' do
    let(:role) { :member }

    it 'refuses and creates no row' do
      expect { open_session(token: developer.token) }.not_to change(ReleaseUpload, :count)

      expect(response).to have_http_status(:forbidden)
    end
  end

  it 'refuses a per-app token, which is for one existing app' do
    owner = developer
    app.create_owner(owner)
    issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

    expect { open_session(headers: { 'Authorization' => "Bearer #{issued.secret}" }) }
      .not_to change(ReleaseUpload, :count)

    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses a request with no credential' do
    expect { open_session }.not_to change(ReleaseUpload, :count)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'still answers 404 for a channel_key that matches nothing, never a silent new app' do
    expect { open_session(token: developer.token, channel_key: 'nope') }.not_to change(ReleaseUpload, :count)

    expect(response).to have_http_status(:not_found)
  end

  it 'lets the uploader read the state of a channel-less session, and nobody else' do
    open_session(token: developer.token)
    id = response.parsed_body['id']
    other = User.create!(email: 'other@example.com', username: 'other', password: password,
                         password_confirmation: password, confirmed_at: Time.current, role: :developer)

    get "/api/apps/upload_sessions/#{id}", params: { token: developer.token }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('id' => id, 'state' => 'awaiting_bytes')

    get "/api/apps/upload_sessions/#{id}", params: { token: other.token }
    expect(response).to have_http_status(:not_found)
  end
end
