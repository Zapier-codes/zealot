# frozen_string_literal: true

require 'rails_helper'

# Task 40r: with REQUIRE_DIRECT_UPLOAD on (and sessions usable), an Android file may not arrive as a multipart
# body on either old door. Everything else keeps the door, and with the flag off nothing changes. Imitates
# manual_upload_only_spec.rb and api_android_signing_key_spec.rb; NOT run (no Rails or database in the sandbox
# that wrote it); look here first if CI is red for this slice.
RSpec.describe 'Direct upload required', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let!(:developer) do
    User.create!(email: 'dev@example.com', username: 'dev', password: password, password_confirmation: password,
                 confirmed_at: Time.current, role: :developer)
  end
  let!(:app) { create(:app, name: 'Gate App') }
  let!(:channel) do
    app.schemes.create!(name: 'Scheme').channels.create!(name: 'Channel', device_type: :android)
  end
  let(:required) { true }

  def file(name)
    Rack::Test::UploadedFile.new(StringIO.new('not really an app'), 'application/octet-stream', true,
                                 original_filename: name)
  end

  def api_upload(name, **params)
    body = { token: developer.token, channel_key: channel.key, file: file(name) }.merge(params)
    post '/api/apps/upload', params: body
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(developer)
    allow(ReleaseUploadSession).to receive(:enabled?).and_return(true)
    stub_const('ENV', ENV.to_hash.merge('REQUIRE_DIRECT_UPLOAD' => required ? 'true' : 'false'))
  end

  describe 'predicates' do
    it 'is required only when the flag is exactly true and sessions are usable' do
      expect(ReleaseUploadSession.direct_upload_required?).to be(true)

      allow(ReleaseUploadSession).to receive(:enabled?).and_return(false)
      expect(ReleaseUploadSession.direct_upload_required?).to be(false)
    end

    it 'knows an Android file by its extension, whatever the case' do
      %w[a.apk a.AAB b.Apk].each { |name| expect(ReleaseUploadSession.android_file?(file(name))).to be(true), name }
      %w[a.ipa a.zip a].each { |name| expect(ReleaseUploadSession.android_file?(file(name))).to be(false), name }
      expect(ReleaseUploadSession.android_file?(nil)).to be(false)
    end
  end

  describe 'POST /api/apps/upload' do
    it 'answers 426 for an .apk and creates nothing' do
      expect { api_upload('app.apk') }.not_to change(Release, :count)

      expect(response).to have_http_status(:upgrade_required)
      expect(response.parsed_body['error']).to include('upload_sessions')
    end

    it 'answers 426 for an .aab' do
      api_upload('app.aab')

      expect(response).to have_http_status(:upgrade_required)
    end

    it 'does not answer 426 for another format' do
      api_upload('app.ipa')

      expect(response).not_to have_http_status(:upgrade_required)
    end

    it 'tells nothing to a caller with no credential' do
      post '/api/apps/upload', params: { channel_key: channel.key, file: file('app.apk') }

      expect(response).to have_http_status(:unauthorized)
    end

    context 'when the flag is off' do
      let(:required) { false }

      it 'does not answer 426 for an .apk' do
        api_upload('app.apk')

        expect(response).not_to have_http_status(:upgrade_required)
      end
    end
  end

  describe 'POST /channels/:channel_id/releases' do
    before { sign_in developer }

    it 'redirects an .apk back to the channel with the reason and creates nothing' do
      expect do
        post channel_releases_path(channel), params: { release: { file: file('app.apk') } }
      end.not_to change(Release, :count)

      expect(response).to have_http_status(:found)
      expect(flash[:alert]).to be_present
    end
  end
end
