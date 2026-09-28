# frozen_string_literal: true

require 'rails_helper'

# Task 27f-b2: the staged-rollout form on the release page (Task 30f) PATCHes the nested resource
# route, `channel_release_path`. It used to PATCH the GET-only friendly route `/:channel/:id`, which
# falls into the not-found catch-all. Needs Postgres. Imitates release_status_control_spec.rb; NOT
# run in the sandbox that wrote it (no Rails boot or database there), so look here first if CI is red.
RSpec.describe 'Release rollout control', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:stranger) do
    User.create!(email: 'stranger@example.com', username: 'stranger', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :developer)
  end
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1', build_version: '1')
           .tap { |r| r.save!(validate: false) }
  end

  before { allow(Setting).to receive(:guest_mode).and_return(false) }

  context 'as a user who manages the app (an admin)' do
    before { sign_in admin }

    it 'points the rollout form at the nested resource route, not the GET-only friendly one' do
      get friendly_channel_release_path(channel, release)

      expect(response.body).to include(%(action="#{channel_release_path(channel, release)}"))
      expect(response.body).not_to include(%(action="#{friendly_channel_release_path(channel, release)}"))
    end

    it 'updates the percentage and redirects back to the release page' do
      patch channel_release_path(channel, release), params: { release: { rollout_percentage: 25 } }

      expect(response).to redirect_to(friendly_channel_release_path(channel, release))
      expect(release.reload.rollout_percentage).to eq(25)
      expect(release.rollout_status).to eq('active')
    end

    it 'halts a rollout without changing the percentage' do
      patch channel_release_path(channel, release), params: { release: { rollout_percentage: 40 } }
      patch channel_release_path(channel, release), params: { release: { rollout_status: 'halted' } }

      expect(release.reload.rollout_status).to eq('halted')
      expect(release.rollout_percentage).to eq(40)
    end

    it 'refuses a percentage over 100 with an alert and changes nothing' do
      patch channel_release_path(channel, release), params: { release: { rollout_percentage: 150 } }

      expect(response).to redirect_to(friendly_channel_release_path(channel, release))
      expect(flash[:alert]).to be_present
      expect(release.reload.rollout_percentage).to eq(100)
    end

    it 'ignores the status column: only the status action may write it' do
      patch channel_release_path(channel, release), params: { release: { rollout_percentage: 30, status: 'pulled' } }

      expect(release.reload.rollout_percentage).to eq(30)
      expect(release.status).to eq('available')
    end
  end

  context 'as a signed-in user with no rights on the app' do
    before { sign_in stranger }

    it 'is forbidden and changes nothing' do
      patch channel_release_path(channel, release), params: { release: { rollout_percentage: 5 } }

      expect(response).to have_http_status(:forbidden)
      expect(release.reload.rollout_percentage).to eq(100)
    end
  end
end
