# frozen_string_literal: true

require 'rails_helper'

# Task 40h-b: the two doors of the direct-to-storage upload, the console
# (`POST /channels/:id/release_uploads[/:id/finalize]`) and the API (`POST /api/apps/upload_sessions[/:id/finalize]`).
# Needs Postgres. Imitates release_status_control_spec.rb (console sign-in) and api_app_token_upload_spec.rb
# (tokens). R2 is a fake: no network. NOT run (the operator said no testing); look here first if CI is red.
RSpec.describe 'Direct upload sessions', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let(:stranger) do
    User.create!(email: 'stranger@example.com', username: 'stranger', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :developer)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }
  let!(:channel) { make_channel(app) }
  let!(:other_channel) { make_channel(other_app) }
  let(:presigned) do
    ReleaseUploadStaging::Presigned.new(url: 'https://r2.example/put?sig=1', method: 'PUT', headers: {},
                                        expires_at: 2.hours.from_now)
  end
  let(:staging) do
    instance_double(ReleaseUploadStaging, presign_put: presigned, delete: true,
                                          head: ReleaseUploadStaging::Head.new(size: 5000, etag: 'e1'))
  end
  let(:enabled) { true }

  def make_channel(target)
    scheme = target.schemes.create!(name: "Scheme #{target.name}")
    scheme.channels.create!(name: "Channel #{target.name}", device_type: :android)
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def api_open(headers: {}, **params)
    post '/api/apps/upload_sessions', params: { filename: 'app.aab', size: 5000 }.merge(params), headers: headers
  end

  def console_open(target = channel, **params)
    post channel_release_uploads_path(target), params: { filename: 'app.aab', size: 5000 }.merge(params)
  end

  before do
    Zealot::TenantRegistry.reset!
    allow(Setting).to receive(:guest_mode).and_return(false)
    allow(ReleaseUploadSession).to receive(:enabled?).and_return(enabled)
    allow(ReleaseUploadStaging).to receive(:new).and_return(staging)
    app.create_owner(owner)
  end

  describe 'API door' do
    it 'opens a session with the user token and creates one awaiting_bytes row for the caller' do
      expect { api_open(token: owner.token, channel_key: channel.key) }.to change(ReleaseUpload, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body).to include('upload_url' => presigned.url, 'method' => 'PUT', 'size' => 5000)
      upload = ReleaseUpload.find(body['id'])
      expect(upload).to have_attributes(user_id: owner.id, channel_id: channel.id, state: 'awaiting_bytes')
      expect(upload.form_options['source']).to eq('api')
    end

    it 'sets the source itself, whatever the client sends' do
      api_open(token: owner.token, channel_key: channel.key, source: 'web')

      expect(ReleaseUpload.last.form_options['source']).to eq('api')
    end

    it 'opens a session with a per-app token for its own app' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      expect { api_open(headers: bearer(issued.secret), channel_key: channel.key) }
        .to change(ReleaseUpload, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it 'refuses a per-app token for another app and creates nothing' do
      issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

      expect { api_open(headers: bearer(issued.secret), channel_key: other_channel.key) }
        .not_to change(ReleaseUpload, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'does not fall back to the user token when a bad per-app token is presented' do
      expect { api_open(headers: bearer("#{AppApiToken::PREFIX}wrong"), token: owner.token, channel_key: channel.key) }
        .not_to change(ReleaseUpload, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a request with no credential, and one with an unknown token' do
      expect { api_open(channel_key: channel.key) }.not_to change(ReleaseUpload, :count)
      expect(response.status).to be >= 400
      expect(response).not_to have_http_status(:created)

      expect { api_open(token: 'not-a-real-token', channel_key: channel.key) }.not_to change(ReleaseUpload, :count)
      expect(response.status).to be >= 400
    end

    it 'refuses a user who may not manage the app (403) and creates nothing' do
      expect { api_open(token: stranger.token, channel_key: channel.key) }.not_to change(ReleaseUpload, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it 'answers 404 for an unknown channel key and never creates a channel' do
      expect { api_open(token: owner.token, channel_key: 'nope') }
        .to change(ReleaseUpload, :count).by(0).and change(Channel, :count).by(0)

      expect(response).to have_http_status(:not_found)
    end

    it 'answers 422 for a size over the cap' do
      api_open(token: owner.token, channel_key: channel.key, size: 2 * 1024**3)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ReleaseUpload.count).to eq(0)
    end

    context 'when the feature is off' do
      let(:enabled) { false }

      it 'answers 404 and creates nothing' do
        expect { api_open(token: owner.token, channel_key: channel.key) }.not_to change(ReleaseUpload, :count)

        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'finalize' do
      let!(:upload) { ReleaseUpload.create!(channel: channel, user: owner, filename: 'app.aab', declared_size: 5000) }

      def api_finalize(id = upload.id, **params)
        post "/api/apps/upload_sessions/#{id}/finalize", params: params.merge(token: owner.token)
      end

      it 'marks the upload uploaded when R2 holds the declared size' do
        api_finalize

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('id' => upload.id, 'state' => 'uploaded')
        expect(upload.reload.state).to eq('uploaded')
      end

      it 'is idempotent' do
        2.times { api_finalize }

        expect(response).to have_http_status(:ok)
        expect(upload.reload.state).to eq('uploaded')
      end

      it 'answers 422 when the staged size is wrong' do
        allow(staging).to receive(:head).and_return(ReleaseUploadStaging::Head.new(size: 1, etag: 'e'))

        api_finalize

        expect(response).to have_http_status(:unprocessable_entity)
        expect(upload.reload.state).to eq('failed')
      end

      it 'answers 404 to a different user and changes nothing' do
        post "/api/apps/upload_sessions/#{upload.id}/finalize", params: { token: stranger.token }

        expect(response).to have_http_status(:not_found)
        expect(upload.reload.state).to eq('awaiting_bytes')
      end

      it 'answers 401 with no credential and changes nothing' do
        post "/api/apps/upload_sessions/#{upload.id}/finalize"

        expect(response).to have_http_status(:unauthorized).or have_http_status(:unprocessable_entity)
        expect(upload.reload.state).to eq('awaiting_bytes')
      end

      it 'refuses a per-app token for another app than the upload belongs to' do
        other = AppApiToken.issue!(app: other_app, name: 'ci', created_by: owner)
        other_app.create_owner(owner)

        post "/api/apps/upload_sessions/#{upload.id}/finalize", headers: bearer(other.secret)

        expect(response.status).to be_between(403, 404)
        expect(upload.reload.state).to eq('awaiting_bytes')
      end
    end

    # Task 40h-c-2: the CI that opened the session polls this for the outcome.
    describe 'show' do
      let!(:upload) { ReleaseUpload.create!(channel: channel, user: owner, filename: 'app.aab', declared_size: 5000) }

      def api_show(id = upload.id, **options)
        get "/api/apps/upload_sessions/#{id}", **options
      end

      it 'answers the state of a session that has no release yet, without release fields' do
        api_show(params: { token: owner.token })

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to eq('id' => upload.id, 'state' => 'awaiting_bytes')
      end

      it 'carries the reason of a failed upload' do
        upload.update_columns(state: 'failed', error: 'package name does not match')

        api_show(params: { token: owner.token })

        expect(response.parsed_body).to include('state' => 'failed', 'error' => 'package name does not match')
      end

      it 'carries the release once there is one, with the fields the CI checks' do
        release = double('Release', id: 77, app: app, status: 'held', release_version: '1.2.3',
                                    build_version: '104', release_url: 'https://zealot.example/r/77')
        allow_any_instance_of(ReleaseUpload).to receive(:release).and_return(release)
        upload.update_columns(state: 'done')

        api_show(params: { token: owner.token })

        expect(response.parsed_body).to include('state' => 'done', 'release_id' => 77, 'app_id' => app.id,
                                                'status' => 'held', 'release_version' => '1.2.3',
                                                'build_version' => '104')
      end

      it 'works with a per-app token for its own app' do
        token = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

        api_show(headers: bearer(token.secret))

        expect(response).to have_http_status(:ok)
      end

      it 'answers 404 to a different user and 404 for an unknown id' do
        api_show(params: { token: stranger.token })
        expect(response).to have_http_status(:not_found)

        api_show(0, params: { token: owner.token })
        expect(response).to have_http_status(:not_found)
      end

      it 'refuses a request with no credential' do
        api_show

        expect(response).to have_http_status(:unauthorized).or have_http_status(:unprocessable_entity)
      end

      it 'refuses a per-app token for another app than the upload belongs to' do
        other = AppApiToken.issue!(app: other_app, name: 'ci', created_by: owner)
        other_app.create_owner(owner)

        api_show(headers: bearer(other.secret))

        expect(response.status).to be_between(403, 404)
      end

      it 'changes nothing' do
        expect { api_show(params: { token: owner.token }) }.not_to(change { upload.reload.attributes })
      end

      context 'when direct upload is switched off' do
        let(:enabled) { false }

        it 'answers 404' do
          api_show(params: { token: owner.token })

          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end

  describe 'console door' do
    context 'signed in as the app owner' do
      before { sign_in owner }

      it 'opens a session and records the signed-in user' do
        expect { console_open }.to change(ReleaseUpload, :count).by(1)

        expect(response).to have_http_status(:created)
        upload = ReleaseUpload.find(response.parsed_body['id'])
        expect(upload).to have_attributes(user_id: owner.id, channel_id: channel.id)
        expect(upload.form_options['source']).to eq('web')
      end

      it 'finalizes the upload it opened' do
        console_open
        id = response.parsed_body['id']

        post finalize_channel_release_upload_path(channel, id)

        expect(response).to have_http_status(:ok)
        expect(ReleaseUpload.find(id).state).to eq('uploaded')
      end

      it 'refuses an upload into an archived app' do
        app.update!(archived: true)

        expect { console_open }.not_to change(ReleaseUpload, :count)
        expect(response).not_to have_http_status(:created)
      end

      context 'when the feature is off' do
        let(:enabled) { false }

        it 'answers 404 and creates nothing' do
          expect { console_open }.not_to change(ReleaseUpload, :count)

          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context 'signed in as a developer who does not manage the app' do
      before { sign_in stranger }

      it 'is refused and creates nothing' do
        expect { console_open }.not_to change(ReleaseUpload, :count)

        expect(response).to have_http_status(:forbidden)
      end
    end

    context 'signed in as another user, finalizing an upload that is not theirs' do
      let!(:upload) { ReleaseUpload.create!(channel: channel, user: owner, filename: 'app.aab', declared_size: 5000) }

      before do
        app.create_owner(stranger)
        sign_in stranger
      end

      it 'answers 404 and changes nothing' do
        post finalize_channel_release_upload_path(channel, upload.id)

        expect(response).to have_http_status(:not_found)
        expect(upload.reload.state).to eq('awaiting_bytes')
      end
    end

    context 'not signed in' do
      it 'creates nothing and does not answer 201' do
        expect { console_open }.not_to change(ReleaseUpload, :count)

        expect(response).not_to have_http_status(:created)
        expect(response.status).to be >= 300
      end
    end
  end

  # Task 40s-c: a large file is opened in parts; the client signs part URLs in batches, resumes by asking R2 which
  # parts it holds, and finalizes. R2 is a fake (the staging double); nothing reaches a network.
  describe 'multipart uploads' do
    let(:size) { 40_000_000 } # 3 parts: 16 MiB, 16 MiB and 6,445,568 bytes
    let(:part_size) { 16 * 1024 * 1024 }
    let(:listed) { [] }
    let(:object) { ReleaseUploadStaging::Head.new(size: size, etag: 'final-3') }
    let(:staging) do
      instance_double(ReleaseUploadStaging, presign_put: presigned, start_multipart: 'mp-1', list_parts: listed,
                                            complete_multipart: true, delete: true, head: object).tap do |double|
        allow(double).to receive(:presign_part) do |_upload, part_number:, expires_in:|
          ReleaseUploadStaging::Presigned.new(url: "https://r2.example/part/#{part_number}?sig=1", method: 'PUT',
                                              headers: {}, expires_at: expires_in.seconds.from_now)
        end
      end
    end
    let!(:upload) do
      ReleaseUpload.create!(channel: channel, user: owner, filename: 'app.aab', declared_size: size,
                            part_size: part_size).tap { |row| row.update_columns(multipart_upload_id: 'mp-1') }
    end

    def held_part(number, bytes)
      ReleaseUploadParts::Held.new(part_number: number, size: bytes, etag: "e#{number}")
    end

    def full_listing
      [held_part(1, part_size), held_part(2, part_size), held_part(3, 6_445_568)]
    end

    before { allow(ReleaseUploadParts).to receive(:use_multipart?) { |bytes| bytes.to_i >= 20_000_000 } }

    describe 'API door' do
      def api_parts(params = {}, id: upload.id, as: owner.token)
        post "/api/apps/upload_sessions/#{id}/parts", params: params.merge(token: as)
      end

      def api_list(id: upload.id, as: owner.token)
        get "/api/apps/upload_sessions/#{id}/parts", params: { token: as }
      end

      it 'opens a large file in parts: the part plan and no upload URL' do
        expect { api_open(token: owner.token, channel_key: channel.key, size: size) }
          .to change(ReleaseUpload, :count).by(1)

        expect(response).to have_http_status(:created)
        body = response.parsed_body
        expect(body).to include('multipart' => true, 'part_size' => part_size, 'part_count' => 3, 'size' => size)
        expect(body).not_to have_key('upload_url')
        expect(ReleaseUpload.find(body['id'])).to have_attributes(part_size: part_size, multipart_upload_id: 'mp-1')
      end

      it 'keeps a small file a single PUT' do
        api_open(token: owner.token, channel_key: channel.key, size: 5000)

        expect(response.parsed_body).to include('upload_url' => presigned.url)
        expect(response.parsed_body).not_to have_key('multipart')
      end

      it 'signs a batch of parts' do
        api_parts(parts: [1, 3])

        expect(response).to have_http_status(:ok)
        parts = response.parsed_body['parts']
        expect(parts.map { |part| part['part_number'] }).to eq([1, 3])
        expect(parts.map { |part| part['size'] }).to eq([part_size, 6_445_568])
        expect(parts.first).to include('method' => 'PUT', 'url' => 'https://r2.example/part/1?sig=1')
      end

      it 'accepts a comma list of part numbers' do
        api_parts(parts: '1,2')

        expect(response.parsed_body['parts'].size).to eq(2)
      end

      it 'answers 422 for part numbers outside the plan, and for none at all' do
        api_parts(parts: [9])
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to have_key('error')

        api_parts
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it 'tells the client what R2 holds, for resuming' do
        allow(staging).to receive(:list_parts).and_return([held_part(1, part_size)])

        api_list

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('part_count' => 3, 'uploaded' => [1], 'missing' => [2, 3])
      end

      it 'finalizes once every part is in R2' do
        allow(staging).to receive(:list_parts).and_return(full_listing)

        post "/api/apps/upload_sessions/#{upload.id}/finalize", params: { token: owner.token }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('state' => 'uploaded')
        expect(staging).to have_received(:complete_multipart)
        expect(upload.reload).to have_attributes(state: 'uploaded', etag: 'final-3')
      end

      it 'answers 422 parts_incomplete with the missing parts and leaves the upload open' do
        allow(staging).to receive(:list_parts).and_return([held_part(1, part_size)])

        post "/api/apps/upload_sessions/#{upload.id}/finalize", params: { token: owner.token }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include('code' => 'parts_incomplete', 'missing' => [2, 3],
                                                'state' => 'awaiting_bytes')
        expect(upload.reload.state).to eq('awaiting_bytes')
      end

      it 'works with a per-app token for its own app' do
        issued = AppApiToken.issue!(app: app, name: 'ci', created_by: owner)

        post "/api/apps/upload_sessions/#{upload.id}/parts", params: { parts: [1] }, headers: bearer(issued.secret)

        expect(response).to have_http_status(:ok)
      end

      it 'refuses a per-app token for another app' do
        other = AppApiToken.issue!(app: other_app, name: 'ci', created_by: owner)
        other_app.create_owner(owner)

        post "/api/apps/upload_sessions/#{upload.id}/parts", params: { parts: [1] }, headers: bearer(other.secret)

        expect(response.status).to be_between(403, 404)
        expect(staging).not_to have_received(:presign_part)
      end

      it 'answers 404 to a different user, for signing and for listing' do
        api_parts({ parts: [1] }, as: stranger.token)
        expect(response).to have_http_status(:not_found)

        api_list(as: stranger.token)
        expect(response).to have_http_status(:not_found)
        expect(staging).not_to have_received(:presign_part)
      end

      it 'refuses a request with no credential' do
        post "/api/apps/upload_sessions/#{upload.id}/parts", params: { parts: [1] }

        expect(response).to have_http_status(:unauthorized).or have_http_status(:unprocessable_entity)
      end

      it 'answers 409 once the upload is no longer open' do
        upload.update_columns(state: 'uploaded')

        api_parts(parts: [1])

        expect(response).to have_http_status(:conflict)
      end

      it 'answers 404 for both while direct upload is switched off' do
        allow(ReleaseUploadSession).to receive(:enabled?).and_return(false)

        api_parts(parts: [1])
        expect(response).to have_http_status(:not_found)

        api_list
        expect(response).to have_http_status(:not_found)
      end
    end

    describe 'console door' do
      before { sign_in owner }

      it 'opens a large file in parts' do
        console_open(size: size)

        expect(response).to have_http_status(:created)
        expect(response.parsed_body).to include('multipart' => true, 'part_size' => part_size, 'part_count' => 3)
        expect(response.parsed_body).not_to have_key('upload_url')
      end

      it 'signs a batch of parts for the upload it opened' do
        post parts_channel_release_upload_path(channel, upload.id), params: { parts: [1, 2] }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['parts'].map { |part| part['part_number'] }).to eq([1, 2])
      end

      it 'tells the client what R2 holds, for resuming' do
        allow(staging).to receive(:list_parts).and_return([held_part(1, part_size), held_part(2, part_size)])

        get list_parts_channel_release_upload_path(channel, upload.id)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body).to include('uploaded' => [1, 2], 'missing' => [3])
      end

      it 'finalizes once every part is in R2, and answers 422 parts_incomplete before that' do
        post finalize_channel_release_upload_path(channel, upload.id)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body).to include('code' => 'parts_incomplete', 'missing' => [1, 2, 3])

        allow(staging).to receive(:list_parts).and_return(full_listing)
        post finalize_channel_release_upload_path(channel, upload.id)
        expect(response).to have_http_status(:ok)
        expect(upload.reload.state).to eq('uploaded')
      end

      it 'answers 404 when the channel is not the upload\'s own' do
        post parts_channel_release_upload_path(other_channel, upload.id), params: { parts: [1] }

        expect(response.status).to be >= 400
        expect(staging).not_to have_received(:presign_part)
      end

      context 'when the feature is off' do
        let(:enabled) { false }

        it 'answers 404' do
          post parts_channel_release_upload_path(channel, upload.id), params: { parts: [1] }

          expect(response).to have_http_status(:not_found)
        end
      end
    end

    describe 'console door as another user' do
      before do
        app.create_owner(stranger)
        sign_in stranger
      end

      it 'answers 404 for signing and listing an upload that is not theirs' do
        post parts_channel_release_upload_path(channel, upload.id), params: { parts: [1] }
        expect(response).to have_http_status(:not_found)

        get list_parts_channel_release_upload_path(channel, upload.id)
        expect(response).to have_http_status(:not_found)
        expect(staging).not_to have_received(:presign_part)
      end
    end
  end
end
