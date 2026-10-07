# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# Task 43a (operator-directed, 2026-10-07): the store-listing graphics over the API (list, add, remove) with
# the user token or a per-app token (header only, own app only). Written by imitating
# api_listing_edit_spec.rb; NOT run (the operator said no testing). Images are built in memory and stored in a
# tmpdir through the real LocalAdapter, like listing_graphic_ingest_spec.rb.
RSpec.describe 'API listing graphics', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }
  let(:root) { Dir.mktmpdir }
  let(:dir) { Dir.mktmpdir }

  def chunk(type, data = ''.b)
    [data.bytesize].pack('N') + type.b + data.b + [Zlib.crc32(type.b + data.b)].pack('N')
  end

  def png(width: 1080, height: 1920)
    ihdr = [width, height, 8, 2, 0, 0, 0].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + chunk('IDAT', 'x') + chunk('IEND')
  end

  def upload(bytes, name = 'shot.png')
    path = File.join(dir, name)
    File.binwrite(path, bytes)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def call(verb, path, secret: nil, **params)
    public_send(verb, path, params: params, headers: secret ? bearer(secret) : {})
  end

  def path(target = app, suffix = '')
    "/api/apps/#{target.id}/listing_graphics#{suffix}"
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
    allow(ReleaseStorage).to receive(:build_adapter).and_return(ReleaseStorage::LocalAdapter.new(root: root))
  end

  after do
    FileUtils.remove_entry(root)
    FileUtils.remove_entry(dir)
  end

  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  it 'refuses every action with no credential' do
    call(:get, path)
    expect(response).to have_http_status(:unprocessable_entity)
    call(:post, path, kind: 'screenshot', file: upload(png))
    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.listing_graphics.count).to eq(0)
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    call(:post, path, secret: "#{AppApiToken::PREFIX}wrong", token: owner.token, kind: 'screenshot', file: upload(png))

    expect(response).to have_http_status(:unauthorized)
    expect(app.listing_graphics.count).to eq(0)
  end

  it 'refuses a valid token for another app (403)' do
    call(:post, path(other_app), secret: issued.secret, kind: 'screenshot', file: upload(png))

    expect(response).to have_http_status(:forbidden)
    expect(other_app.listing_graphics.count).to eq(0)
  end

  it 'adds a screenshot with the per-app token and lists it' do
    call(:post, path, secret: issued.secret, kind: 'screenshot', alt_text: 'Home screen', file: upload(png))

    expect(response).to have_http_status(:created)
    body = response.parsed_body
    expect(body.dig('graphic', 'kind')).to eq('screenshot')
    expect(body.dig('graphic', 'alt_text')).to eq('Home screen')
    expect(body.dig('graphic', 'sha256')).to be_present
    expect(app.listing_graphics.kind_screenshot.count).to eq(1)

    call(:get, path, secret: issued.secret)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['screenshots_count']).to eq(1)
    expect(response.parsed_body['feature_graphic']).to be(false)
  end

  it 'adds a screenshot with the user token' do
    call(:post, path, token: owner.token, kind: 'screenshot', file: upload(png))

    expect(response).to have_http_status(:created)
    expect(app.listing_graphics.count).to eq(1)
  end

  it 'refuses a picture Play would refuse, with every reason, and stores nothing (fit=false sends it as it is)' do
    call(:post, path, secret: issued.secret, kind: 'screenshot', fit: 'false', file: upload(png(width: 1080, height: 2400)))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to be_present
    expect(app.listing_graphics.count).to eq(0)
  end

  it 'refuses a request with no file' do
    call(:post, path, secret: issued.secret, kind: 'screenshot')

    expect(response).to have_http_status(:unprocessable_entity)
    expect(app.listing_graphics.count).to eq(0)
  end

  it 'removes a graphic, and not another app\'s' do
    call(:post, path, secret: issued.secret, kind: 'screenshot', file: upload(png))
    id = response.parsed_body.dig('graphic', 'id')

    call(:delete, path(app, "/#{id}"), secret: issued.secret)
    expect(response).to have_http_status(:ok)
    expect(app.listing_graphics.count).to eq(0)

    call(:delete, path(other_app, "/#{id}"), secret: issued.secret)
    expect(response).to have_http_status(:forbidden)
  end
end
