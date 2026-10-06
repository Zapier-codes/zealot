# frozen_string_literal: true

require 'rails_helper'

# Task 40h-c: the upload form switches to direct-to-storage mode only while ReleaseUploadSession.enabled? is
# true, and every message the Stimulus controller shows exists in both locales. Needs Postgres. Imitates
# release_upload_sessions_spec.rb. NOT run (the operator said no testing); look here first if CI is red.
RSpec.describe 'Release upload form, direct mode', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Form App') }
  let!(:channel) do
    scheme = app.schemes.create!(name: 'Form Scheme')
    scheme.channels.create!(name: 'Form Channel', device_type: :android)
  end

  before do
    Zealot::TenantRegistry.reset!
    allow(Setting).to receive(:guest_mode).and_return(false)
    allow(ReleaseUploadSession).to receive(:enabled?).and_return(enabled)
    app.create_owner(owner)
    sign_in owner
  end

  context 'with direct upload off' do
    let(:enabled) { false }

    it 'renders the plain multipart form with no direct-upload wiring' do
      get new_channel_release_path(channel)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('direct-upload#submit')
      expect(response.body).not_to include('data-direct-upload-target="status"')
    end
  end

  context 'with direct upload on' do
    let(:enabled) { true }

    it 'wires the form to the console session URL and carries the messages' do
      get new_channel_release_path(channel)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-controller="direct-upload"')
      expect(response.body).to include('direct-upload#submit')
      expect(response.body).to include("data-direct-upload-session-url-value=\"#{channel_release_uploads_path(channel)}\"")
      expect(response.body).to include('data-direct-upload-messages-value=')
      expect(response.body).to include('resuming')
      expect(response.body).to include('data-direct-upload-target="status"')
    end
  end

  describe 'messages' do
    let(:enabled) { false }
    let(:keys) { ReleasesHelper::DIRECT_UPLOAD_MESSAGE_KEYS + %w[back_to_channel] }

    it 'exist in both locales, and the progress text keeps its placeholder' do
      %i[en zh-CN].each do |locale|
        keys.each do |key|
          expect(I18n.exists?("releases.direct_upload.#{key}", locale)).to be(true), "#{locale} is missing #{key}"
        end
        expect(I18n.t('releases.direct_upload.sending', locale: locale)).to include('{percent}')
        expect(I18n.t('releases.direct_upload.resuming', locale: locale)).to include('{percent}')
      end
    end
  end
end
