# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-b: the store-graphics panel on the app page (GET /apps/:id). Needs Postgres. NOT run in
# the sandbox that wrote it (no Rails boot or database there, and the Slim gem could not be fetched),
# so look here first if CI is red. The endpoints the panel posts to are covered by
# listing_graphics_upload_spec.rb; this spec only covers who sees the panel and what it shows.
RSpec.describe 'Listing graphics panel on the app page', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def add_graphic(kind:, position: 0, stored: true, alt_text: nil, width: 1080, height: 1920)
    ListingGraphic.create!(app: app, kind: kind, device: 'phone', position: position,
                           content_type: 'image/png', byte_size: 1234, width: width, height: height,
                           alt_text: alt_text, sha256: (stored ? 'a' * 64 : nil),
                           storage_key: (stored ? "graphics/#{SecureRandom.hex(4)}.png" : nil))
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Shown app') }
  let(:title) { I18n.t('apps.show.listing_graphics.title') }

  before do
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  context 'as the app owner' do
    before { sign_in owner }

    it 'shows the panel with an upload form that posts to the graphics endpoint' do
      get app_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(title)
      expect(response.body).to include(%(action="#{app_listing_graphics_path(app)}"))
      expect(response.body).to include('listing_graphic[file]', 'listing_graphic[kind]', 'listing_graphic[alt_text]')
      expect(response.body).to include(I18n.t('apps.show.listing_graphics.no_screenshots'))
    end

    it 'lists screenshots in position order with a thumbnail from the public graphic URL' do
      second = add_graphic(kind: 'screenshot', position: 1, alt_text: 'Settings')
      first = add_graphic(kind: 'screenshot', position: 0, alt_text: 'Home')

      get app_path(app)

      expect(response.body).to include(download_graphic_path(first), download_graphic_path(second))
      expect(response.body.index(download_graphic_path(first))).to be < response.body.index(download_graphic_path(second))
      expect(response.body).to include(I18n.t('apps.show.listing_graphics.screenshots_used', used: 2, max: 8))
    end

    it 'shows the feature graphic and a remove button for each graphic' do
      shot = add_graphic(kind: 'screenshot')
      feature = add_graphic(kind: 'feature_graphic', width: 1024, height: 500)

      get app_path(app)

      expect(response.body).to include(download_graphic_path(feature))
      expect(response.body).to include(%(action="#{app_listing_graphic_path(app, shot)}"))
      expect(response.body).to include(%(action="#{app_listing_graphic_path(app, feature)}"))
      expect(response.body).not_to include(I18n.t('apps.show.listing_graphics.no_feature_graphic'))
    end

    it 'offers a description form on every graphic and move buttons only where a move is possible' do
      first = add_graphic(kind: 'screenshot', position: 0)
      second = add_graphic(kind: 'screenshot', position: 1)
      feature = add_graphic(kind: 'feature_graphic', width: 1024, height: 500)

      get app_path(app)

      [ first, second, feature ].each do |graphic|
        expect(response.body).to include(%(action="#{app_listing_graphic_path(app, graphic)}"))
      end
      # first can only go later, second only earlier, the feature graphic has no order
      expect(response.body.scan(move_app_listing_graphic_path(app, first)).size).to eq(1)
      expect(response.body.scan(move_app_listing_graphic_path(app, second)).size).to eq(1)
      expect(response.body).not_to include(move_app_listing_graphic_path(app, feature))
    end

    it 'shows the promo video box, and a link only when a video is set' do
      get app_path(app)
      expect(response.body).to include(%(action="#{app_promo_video_path(app)}"), I18n.t('apps.show.listing_graphics.video.none'))
      expect(response.body).not_to include('https://youtu.be/')

      app.update!(promo_video_youtube_id: 'dQw4w9WgXcQ')
      get app_path(app)

      expect(response.body).to include('https://youtu.be/dQw4w9WgXcQ', 'rel="noopener noreferrer"')
      expect(response.body).to include(I18n.t('apps.show.listing_graphics.video.remove'))
    end

    # Task 27d-e2-e: the Play checklist is advice, ticked from what the index will carry.
    it 'shows the Play checklist with nothing ticked for an app with no graphics' do
      get app_path(app)

      expect(response.body).to include('id="listing-graphics-checklist"')
      expect(response.body).to include(I18n.t('apps.show.listing_graphics.checklist.summary', met: 0, total: 5))
      expect(response.body.scan('data-met="false"').size).to eq(5)
      expect(response.body).not_to include('data-met="true"')
    end

    it 'ticks the checklist as stored graphics, a description and a video are added' do
      2.times { |i| add_graphic(kind: 'screenshot', position: i, alt_text: 'Home') }
      add_graphic(kind: 'feature_graphic', alt_text: 'Cover', width: 1024, height: 500)
      app.update!(promo_video_youtube_id: 'dQw4w9WgXcQ')

      get app_path(app)

      expect(response.body).to include(I18n.t('apps.show.listing_graphics.checklist.summary', met: 4, total: 5))
      expect(response.body).to include('data-checklist-item="min_screenshots" data-met="true"')
      expect(response.body).to include('data-checklist-item="promo_screenshots" data-met="false"')
      expect(response.body).to include('data-checklist-item="video" data-met="true"')
    end

    it 'does not tick anything for a row whose bytes are not stored yet' do
      2.times { |i| add_graphic(kind: 'screenshot', position: i, stored: false) }

      get app_path(app)

      expect(response.body).to include('data-checklist-item="min_screenshots" data-met="false"')
    end

    it 'shows a placeholder, not a broken image, for a row whose bytes are not stored yet' do
      pending_row = add_graphic(kind: 'screenshot', stored: false)

      get app_path(app)

      expect(response.body).to include(I18n.t('apps.show.listing_graphics.not_stored'))
      expect(response.body).not_to include(%(src="#{download_graphic_path(pending_row)}"))
    end

    it 'shows no panel on an archived app' do
      app.update_columns(archived: true)

      get app_path(app)

      expect(response.body).not_to include(title)
    end

    it "does not show another app's graphics" do
      other = create(:app, name: 'Other app')
      foreign = ListingGraphic.new(app: other, kind: 'screenshot', device: 'phone', position: 0,
                                   content_type: 'image/png', byte_size: 9, width: 1080, height: 1920,
                                   sha256: 'b' * 64, storage_key: 'graphics/other.png')
                              .tap { |record| record.save!(validate: false) }

      get app_path(app)

      expect(response.body).not_to include(download_graphic_path(foreign))
    end
  end

  context 'as an admin' do
    it 'shows the panel' do
      sign_in admin

      get app_path(app)

      expect(response.body).to include(title)
    end
  end

  context 'as a plain member collaborator' do
    it 'shows the app page without the panel' do
      add_graphic(kind: 'screenshot')
      sign_in teammate

      get app_path(app)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(title)
    end
  end
end
