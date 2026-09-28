# frozen_string_literal: true

require 'rails_helper'

# Task 27f-b: the release-page control that holds, releases, halts, resumes, pulls and restores a
# release (`PATCH /channels/:channel_id/releases/:id/status`). Needs Postgres. Imitates
# console_debug_files_teardowns_tenant_spec.rb (sign-in, release construction); NOT run in the
# sandbox that wrote it (no Rails boot or database there), so look here first if CI is red.
RSpec.describe 'Release status control', type: :request do
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

  def change_status(to)
    patch status_channel_release_path(channel, release), params: { release: { status: to } }
  end

  before { allow(Setting).to receive(:guest_mode).and_return(false) }

  context 'as a user who manages the app (an admin)' do
    before { sign_in admin }

    it 'holds an available release and redirects back to the release page' do
      change_status('held')

      expect(response).to redirect_to(friendly_channel_release_path(channel, release))
      expect(release.reload.status).to eq('held')
    end

    it 'walks a release through hold, release, halt, resume, pull and restore' do
      %w[held available halted available pulled available].each do |state|
        change_status(state)
        expect(release.reload.status).to eq(state)
      end
    end

    it 'refuses a move the page does not offer and changes nothing' do
      release.update!(status: 'pulled')

      change_status('held')

      expect(response).to redirect_to(friendly_channel_release_path(channel, release))
      expect(flash[:alert]).to be_present
      expect(release.reload.status).to eq('pulled')
    end

    it 'refuses an unknown value and a blank one' do
      ['deleted', ''].each do |value|
        change_status(value)
        expect(flash[:alert]).to be_present
        expect(release.reload.status).to eq('available')
      end
    end

    it 'refuses a repeat of the current status (no move offered to itself)' do
      change_status('available')

      expect(flash[:alert]).to be_present
      expect(release.reload.status).to eq('available')
    end

    it 'does not let this action write the rollout columns' do
      patch status_channel_release_path(channel, release),
            params: { release: { status: 'halted', rollout_percentage: 5, rollout_status: 'halted' } }

      expect(release.reload.status).to eq('halted')
      expect(release.rollout_percentage).to eq(100)
      expect(release.rollout_status).not_to eq('halted')
    end

    it 'enqueues one catalog publish for a change and none for a refused one' do
      allow(CatalogIndexPublishJob).to receive(:enqueue_for)

      change_status('held')
      change_status('halted') # refused: held cannot go to halted

      expect(CatalogIndexPublishJob).to have_received(:enqueue_for).with(app.tenant).once
    end

    it 'shows the current status and only the moves offered from it on the release page' do
      release.update!(status: 'halted')

      get friendly_channel_release_path(channel, release)

      expect(response.body).to include(I18n.t('releases.show.status_actions.resume'),
                                       I18n.t('releases.show.status_actions.pull'))
      expect(response.body).not_to include(I18n.t('releases.show.status_actions.hold'))
    end
  end

  context 'as a signed-in user with no rights on the app' do
    before { sign_in stranger }

    it 'is forbidden and changes nothing' do
      change_status('pulled')

      expect(response).to have_http_status(:forbidden)
      expect(release.reload.status).to eq('available')
    end
  end

  context 'when signed out' do
    it 'sends the visitor to sign in and changes nothing' do
      change_status('pulled')

      expect(response).to redirect_to(new_user_session_path)
      expect(release.reload.status).to eq('available')
    end
  end
end
