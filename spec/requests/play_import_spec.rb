# frozen_string_literal: true

require 'rails_helper'

# Z-P25 §2: GET/POST /apps/:app_id/play_import ("Import from Play"). Needs Postgres. NOT run in the sandbox
# that wrote it (no Rails boot or database there). The Google client is stubbed through the service, since
# the androidpublisher gem is not installed here — this file checks the *page*: who may use it, that it
# stages a draft and never writes the live listing, that it never sends anything back to Play, and how it
# behaves when Play answers with a problem.
RSpec.describe 'Import from Play', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Live name', short_description: 'Live short', description: 'Live long',
                            play_package_name: 'com.example.app') }

  before do
    Zealot::TenantRegistry.reset!
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  # A Result with one en-US listing, the shape the controller reads.
  def ok_result(title: 'Play name', short: 'Play short', full: 'Play long', language: 'en-US')
    listing = Anthropic::PlayImportService::Listing.new(
      language: language, title: title, short_description: short, full_description: full
    )
    Anthropic::PlayImportService::Result.new(
      code: :ok, package_name: 'com.example.app', listings: [listing], tracks: []
    )
  end

  def stub_fetch(result)
    stub_reads
    allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch).and_return(result)
  end

  # Reviews and vitals are independent reads the page also makes; stub them empty by
  # default so a listing test is not affected by them, and let individual tests override.
  def stub_reads
    allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch_reviews)
      .and_return(Anthropic::PlayImportService::ReviewsResult.new(code: :ok, package_name: 'com.example.app', reviews: []))
    allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch_vitals)
      .and_return(Anthropic::PlayImportService::VitalsResult.new(code: :ok, package_name: 'com.example.app', vitals: []))
  end

  def draft
    app.listing_edits.status_draft.first
  end

  describe 'authorization' do
    it 'lets the owner open the page' do
      sign_in owner
      stub_fetch(ok_result)

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
    end

    it 'forbids a stranger' do
      sign_in stranger
      stub_fetch(ok_result)

      get app_play_import_path(app)

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'GET' do
    before { sign_in owner }

    it 'shows what Play holds and creates no draft' do
      stub_fetch(ok_result(title: 'Play name'))

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Play name', 'Play short', 'Play long')
      expect(app.listing_edits.count).to eq(0)
    end

    it 'shows the message when Play reports a problem' do
      stub_fetch(Anthropic::PlayImportService::Result.new(code: :not_configured, message: 'No Play API credential'))

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('No Play API credential')
      expect(app.listing_edits.count).to eq(0)
    end

    it 'renders Play reviews, including the developer reply' do
      stub_fetch(ok_result)
      allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch_reviews).and_return(
        Anthropic::PlayImportService::ReviewsResult.new(code: :ok, package_name: 'com.example.app', reviews: [
          Anthropic::PlayImportService::ReviewInfo.new(author_name: 'Ada', rating: 5, text: 'wonderful',
                                                       developer_reply: 'thanks!', replied_at: Date.new(2026, 10, 8))
        ])
      )

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Ada', 'wonderful', 'thanks!')
    end

    it 'says so when Play has no reviews' do
      stub_fetch(ok_result)

      get app_play_import_path(app)

      expect(response.body).to include(I18n.t('apps.play_imports.show.no_reviews'))
    end

    it 'renders crash and ANR rates, and "not measured" when a datapoint is missing' do
      stub_fetch(ok_result)
      allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch_vitals).and_return(
        Anthropic::PlayImportService::VitalsResult.new(code: :ok, package_name: 'com.example.app', vitals: [
          Anthropic::PlayImportService::VitalInfo.new(kind: 'crashRate', start_time: '2026-10-09', value: '0.55', user_count: '1234'),
          Anthropic::PlayImportService::VitalInfo.new(kind: 'anrRate', start_time: '2026-10-09', value: nil)
        ])
      )

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('0.55%', 'Crash rate', 'ANR rate', '1,234')
      expect(response.body).to include(I18n.t('apps.play_imports.show.not_measured'))
    end

    it 'shows the reviews problem without blanking the listing when only reviews fail' do
      stub_fetch(ok_result(title: 'Play name'))
      allow_any_instance_of(Anthropic::PlayImportService).to receive(:fetch_reviews).and_return(
        Anthropic::PlayImportService::ReviewsResult.new(code: :access_denied, message: 'Reviews access denied')
      )

      get app_play_import_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Play name', 'Reviews access denied')
    end
  end

  describe 'POST' do
    before { sign_in owner }

    it 'stages the listing into the draft and never writes the live app' do
      stub_fetch(ok_result(title: 'Play name', short: 'Play short', full: 'Play long'))

      post app_play_import_path(app)

      expect(response).to redirect_to(app_listing_text_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.play_imports.create.staged'))
      expect(draft.staged_attributes).to eq('name' => 'Play name', 'short_description' => 'Play short',
                                            'description' => 'Play long')
      app.reload
      expect([ app.name, app.short_description, app.description ]).to eq([ 'Live name', 'Live short', 'Live long' ])
    end

    it 'stages only the fields that differ from the live listing' do
      stub_fetch(ok_result(title: 'Live name', short: 'Live short', full: 'Play long'))

      post app_play_import_path(app)

      expect(draft.staged_attributes).to eq('description' => 'Play long')
    end

    it 'does not republish the catalog index (nothing live changes)' do
      stub_fetch(ok_result)

      expect { post app_play_import_path(app) }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'says so when the live listing already matches Play' do
      stub_fetch(ok_result(title: 'Live name', short: 'Live short', full: 'Live long'))

      post app_play_import_path(app)

      expect(response).to redirect_to(app_play_import_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.play_imports.create.unchanged'))
      expect(app.listing_edits.count).to eq(0)
    end

    it 'does not stage when Play reports a problem' do
      stub_fetch(Anthropic::PlayImportService::Result.new(code: :package_not_found, message: 'no app'))

      post app_play_import_path(app)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(app.listing_edits.count).to eq(0)
    end

    it 'adopts the package name when the app has none' do
      app.update!(play_package_name: nil)
      stub_fetch(ok_result(title: 'Play name'))

      post app_play_import_path(app)

      expect(app.reload.play_package_name).to eq('com.example.app')
    end

    it 'never overwrites a package name the app already set' do
      app.update!(play_package_name: 'com.other.app')
      result = ok_result(title: 'Play name')
      result.package_name = 'com.example.app'
      stub_fetch(result)

      post app_play_import_path(app)

      expect(app.reload.play_package_name).to eq('com.other.app')
    end
  end
end
