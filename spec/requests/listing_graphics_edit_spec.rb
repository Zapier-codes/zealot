# frozen_string_literal: true

require 'rails_helper'

# Task 27d-e2-c: PATCH /apps/:app_id/listing_graphics/:id (the description) and
# PATCH /apps/:app_id/listing_graphics/:id/move (up or down). Needs Postgres. NOT run in the sandbox
# that wrote it (no Rails boot or database there), so look here first if CI is red.
RSpec.describe 'Listing graphic description and order', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def add_graphic(target = app, kind: 'screenshot', position: 0, alt_text: nil)
    width, height = kind == 'feature_graphic' ? [ 1024, 500 ] : [ 1080, 1920 ]
    ListingGraphic.create!(app: target, kind: kind, device: 'phone', position: position,
                           content_type: 'image/png', byte_size: 1234, width: width, height: height,
                           alt_text: alt_text, sha256: 'a' * 64, storage_key: "graphics/#{SecureRandom.hex(4)}.png")
  end

  def order
    app.listing_graphics.where(kind: 'screenshot').order(:position).pluck(:id)
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Edited app') }
  let!(:first_shot) { add_graphic(position: 0, alt_text: 'Home') }
  let!(:second_shot) { add_graphic(position: 1, alt_text: 'Settings') }

  before do
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  context 'as the app owner' do
    before { sign_in owner }

    it 'changes the description and nothing else' do
      before_attrs = first_shot.attributes.slice('kind', 'position', 'sha256', 'storage_key', 'width')

      patch app_listing_graphic_path(app, first_shot),
            params: { listing_graphic: { alt_text: ' New words ', kind: 'feature_graphic', position: 5, sha256: 'b' * 64 } }

      expect(response).to redirect_to(app_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.listing_graphics.update.notice'))
      expect(first_shot.reload.alt_text).to eq('New words')
      expect(first_shot.attributes.slice('kind', 'position', 'sha256', 'storage_key', 'width')).to eq(before_attrs)
    end

    it 'clears the description when it is blank' do
      patch app_listing_graphic_path(app, first_shot), params: { listing_graphic: { alt_text: '   ' } }

      expect(first_shot.reload.alt_text).to be_nil
    end

    it 'refuses a description over the limit and keeps the old one' do
      too_long = 'x' * (ListingGraphicRules::ALT_TEXT_MAX_LENGTH + 1)

      patch app_listing_graphic_path(app, first_shot), params: { listing_graphic: { alt_text: too_long } }

      expect(flash[:alert]).to be_present
      expect(first_shot.reload.alt_text).to eq('Home')
    end

    it 'can describe the feature graphic too' do
      feature = add_graphic(kind: 'feature_graphic', alt_text: nil)

      patch app_listing_graphic_path(app, feature), params: { listing_graphic: { alt_text: 'Banner' } }

      expect(feature.reload.alt_text).to eq('Banner')
    end

    it 'moves a screenshot earlier' do
      patch move_app_listing_graphic_path(app, second_shot), params: { direction: 'up' }

      expect(response).to redirect_to(app_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.listing_graphics.move.moved'))
      expect(order).to eq([ second_shot.id, first_shot.id ])
    end

    it 'moves a screenshot later' do
      patch move_app_listing_graphic_path(app, first_shot), params: { direction: 'down' }

      expect(order).to eq([ second_shot.id, first_shot.id ])
    end

    it 'says so, and changes nothing, when the screenshot is already at the end' do
      patch move_app_listing_graphic_path(app, first_shot), params: { direction: 'up' }

      expect(flash[:notice]).to eq(I18n.t('apps.listing_graphics.move.unchanged'))
      expect(order).to eq([ first_shot.id, second_shot.id ])
    end

    it 'refuses an unknown direction' do
      patch move_app_listing_graphic_path(app, first_shot), params: { direction: 'sideways' }

      expect(flash[:alert]).to eq(I18n.t('apps.listing_graphics.move.bad_direction'))
      expect(order).to eq([ first_shot.id, second_shot.id ])
    end

    it 'enqueues one index publish for a live app, however many rows moved' do
      third = add_graphic(position: 2)
      allow_any_instance_of(App).to receive(:listing_live?).and_return(true)

      expect { patch move_app_listing_graphic_path(app, third), params: { direction: 'up' } }
        .to have_enqueued_job(CatalogIndexPublishJob).exactly(:once)
    end

    it 'cannot move the feature graphic: not found, nothing changes' do
      feature = add_graphic(kind: 'feature_graphic')

      patch move_app_listing_graphic_path(app, feature), params: { direction: 'up' }

      expect(response).to have_http_status(:not_found)
    end

    it "cannot edit or move another app's graphic through this app's URL" do
      other = create(:app, name: 'Other app')
      foreign = add_graphic(other, alt_text: 'Theirs')

      patch app_listing_graphic_path(app, foreign), params: { listing_graphic: { alt_text: 'Mine now' } }
      expect(response).to have_http_status(:not_found)

      patch move_app_listing_graphic_path(app, foreign), params: { direction: 'down' }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.alt_text).to eq('Theirs')
    end

    it 'refuses an archived app' do
      app.update_columns(archived: true)

      patch app_listing_graphic_path(app, first_shot), params: { listing_graphic: { alt_text: 'Changed' } }
      patch move_app_listing_graphic_path(app, second_shot), params: { direction: 'up' }

      expect(first_shot.reload.alt_text).to eq('Home')
      expect(order).to eq([ first_shot.id, second_shot.id ])
    end
  end

  context 'as an admin' do
    it 'may edit and move on any app' do
      sign_in admin

      patch move_app_listing_graphic_path(app, second_shot), params: { direction: 'up' }

      expect(order).to eq([ second_shot.id, first_shot.id ])
    end
  end

  context 'as a plain member collaborator, an unrelated developer or a signed-out visitor' do
    it 'is refused and changes nothing' do
      [ teammate, stranger ].each do |user|
        sign_in user
        patch app_listing_graphic_path(app, first_shot), params: { listing_graphic: { alt_text: 'Hacked' } }
        expect(response).to have_http_status(:forbidden)
        patch move_app_listing_graphic_path(app, second_shot), params: { direction: 'up' }
        expect(response).to have_http_status(:forbidden)
        sign_out user
      end

      patch app_listing_graphic_path(app, first_shot), params: { listing_graphic: { alt_text: 'Hacked' } }
      expect(response).not_to have_http_status(:ok)

      expect(first_shot.reload.alt_text).to eq('Home')
      expect(order).to eq([ first_shot.id, second_shot.id ])
    end
  end
end
