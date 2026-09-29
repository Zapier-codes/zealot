# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# Task 27d-e2-a: POST /apps/:app_id/listing_graphics and DELETE /apps/:app_id/listing_graphics/:id.
# Needs Postgres. Images are built in memory (no binary fixtures), like listing_graphic_ingest_spec.rb,
# and stored through a real LocalAdapter over a tmpdir. NOT run in the sandbox that wrote it (no Rails
# boot or database there), so look here first if CI is red.
RSpec.describe 'Listing graphic upload and removal', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def chunk(type, data = ''.b)
    [ data.bytesize ].pack('N') + type.b + data.b + [ Zlib.crc32(type.b + data.b) ].pack('N')
  end

  def png(width: 1080, height: 1920, color_type: 2)
    ihdr = [ width, height, 8, color_type, 0, 0, 0 ].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + chunk('IDAT', 'x') + chunk('IEND')
  end

  def upload(bytes, name: 'shot.png', type: 'image/png')
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    Rack::Test::UploadedFile.new(path, type)
  end

  def post_graphic(file, kind: 'screenshot', alt_text: nil)
    post app_listing_graphics_path(app),
         params: { listing_graphic: { file: file, kind: kind, alt_text: alt_text } }
  end

  let(:dir) { Dir.mktmpdir }
  let(:root) { Dir.mktmpdir }
  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Shown app') }

  before do
    allow(Setting).to receive(:guest_mode).and_return(false)
    allow(ReleaseStorage).to receive(:build_adapter).and_return(ReleaseStorage::LocalAdapter.new(root: root))
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  after do
    FileUtils.remove_entry(dir)
    FileUtils.remove_entry(root)
  end

  context 'as the app owner' do
    before { sign_in owner }

    it 'adds a screenshot: a row with its hash and key, bytes stored, back to the app page' do
      post_graphic(upload(png), alt_text: 'Home screen')

      graphic = app.listing_graphics.sole
      expect(response).to redirect_to(app_path(app))
      expect(flash[:notice]).to eq(I18n.t('apps.listing_graphics.create.added.screenshot'))
      expect(graphic).to have_attributes(kind: 'screenshot', position: 0, alt_text: 'Home screen',
                                         content_type: 'image/png', width: 1080, height: 1920)
      expect(graphic.sha256).to match(/\A\h{64}\z/)
      expect(File.exist?(File.join(root, graphic.storage_key))).to be true
    end

    it 'gives each new screenshot the next position' do
      2.times { post_graphic(upload(png)) }

      expect(app.listing_graphics.ordered.pluck(:position)).to eq([ 0, 1 ])
    end

    it 'sets the feature graphic and replaces the old one' do
      post_graphic(upload(png(width: 1024, height: 500), name: 'a.png'), kind: 'feature_graphic')
      post_graphic(upload(png(width: 1024, height: 500), name: 'b.png'), kind: 'feature_graphic')

      expect(app.listing_graphics.where(kind: 'feature_graphic').count).to eq(1)
      expect(flash[:notice]).to eq(I18n.t('apps.listing_graphics.create.added.feature_graphic'))
    end

    it 'trusts the bytes, not the name: an alpha PNG called .jpg is refused and nothing is written' do
      post_graphic(upload(png(color_type: 6), name: 'shot.jpg', type: 'image/jpeg'))

      expect(response).to redirect_to(app_path(app))
      expect(flash[:alert]).to be_present
      expect(app.listing_graphics.count).to eq(0)
      expect(Dir.glob(File.join(root, '**', '*')).select { |path| File.file?(path) }).to be_empty
    end

    it 'refuses a ninth screenshot and says why' do
      8.times { post_graphic(upload(png)) }

      post_graphic(upload(png))

      expect(app.listing_graphics.where(kind: 'screenshot').count).to eq(8)
      expect(flash[:alert]).to include('8')
    end

    it 'refuses an unknown kind' do
      post_graphic(upload(png), kind: 'banner')

      expect(flash[:alert]).to be_present
      expect(app.listing_graphics.count).to eq(0)
    end

    it 'asks for a file when none is sent' do
      post app_listing_graphics_path(app), params: { listing_graphic: { kind: 'screenshot' } }

      expect(flash[:alert]).to eq(I18n.t('apps.listing_graphics.create.no_file'))
      expect(app.listing_graphics.count).to eq(0)
    end

    it 'reports a storage failure without keeping a row' do
      adapter = instance_double(ReleaseStorage::LocalAdapter)
      allow(adapter).to receive(:put).and_raise(ReleaseStorage::StorageError, 'disk full')
      allow(adapter).to receive(:delete)
      allow(ReleaseStorage).to receive(:build_adapter).and_return(adapter)

      post_graphic(upload(png))

      expect(flash[:alert]).to eq(I18n.t('apps.listing_graphics.create.storage_failed'))
      expect(app.listing_graphics.count).to eq(0)
    end

    it 'refuses an archived app' do
      app.update_columns(archived: true)

      post_graphic(upload(png))

      expect(app.listing_graphics.count).to eq(0)
    end

    it 'removes a graphic and enqueues the cleanup of its bytes' do
      post_graphic(upload(png))
      graphic = app.listing_graphics.sole

      expect { delete app_listing_graphic_path(app, graphic) }
        .to have_enqueued_job(ListingGraphicStorageCleanupJob)

      expect(response).to redirect_to(app_path(app))
      expect(app.listing_graphics.count).to eq(0)
    end

    it "cannot remove another app's graphic through this app's URL" do
      other = create(:app, name: 'Other app')
      foreign = ListingGraphic.new(app: other, kind: 'screenshot', device: 'phone', position: 0,
                                   content_type: 'image/png', byte_size: 9, width: 1080, height: 1920)
                              .tap { |record| record.save!(validate: false) }

      delete app_listing_graphic_path(app, foreign)

      expect(response).to have_http_status(:not_found)
      expect(ListingGraphic.exists?(foreign.id)).to be true
    end
  end

  context 'as an admin' do
    before { sign_in admin }

    it 'may add a screenshot to any app' do
      post_graphic(upload(png))

      expect(app.listing_graphics.count).to eq(1)
    end
  end

  context 'as a plain member collaborator or an unrelated developer' do
    it 'is forbidden and writes nothing' do
      [ teammate, stranger ].each do |user|
        sign_in user
        post_graphic(upload(png))

        expect(response).to have_http_status(:forbidden)
        sign_out user
      end
      expect(app.listing_graphics.count).to eq(0)
    end

    it 'may not remove a graphic either' do
      sign_in owner
      post_graphic(upload(png))
      graphic = app.listing_graphics.sole
      sign_out owner

      sign_in stranger
      delete app_listing_graphic_path(app, graphic)

      expect(response).to have_http_status(:forbidden)
      expect(ListingGraphic.exists?(graphic.id)).to be true
    end
  end

  context 'when signed out' do
    it 'sends the visitor to sign in and writes nothing' do
      post_graphic(upload(png))

      expect(response).to have_http_status(:found)
      expect(app.listing_graphics.count).to eq(0)
    end
  end

  context 'on a tenant host' do
    let(:acme) { create(:tenant, tenant_id: 'acme', domains: [ 'store.acme.example.com' ]) }
    let(:globex) { create(:tenant, tenant_id: 'globex', domains: [ 'store.globex.example.com' ]) }

    before do
      Zealot::TenantRegistry.reset!
      TenantMembership.create!(tenant: acme, user: owner)
      host! 'store.acme.example.com'
      sign_in owner
    end

    it "lets a member add a graphic to the tenant's own app" do
      app.update_columns(tenant_id: acme.id)

      post_graphic(upload(png))

      expect(app.listing_graphics.count).to eq(1)
    end

    it "refuses another tenant's app, even for a member of this host's tenant" do
      app.update_columns(tenant_id: globex.id)

      post_graphic(upload(png))

      expect(response).to have_http_status(:forbidden)
      expect(app.listing_graphics.count).to eq(0)
    end
  end
end
