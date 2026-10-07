# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'
require 'zlib'

# Task 43f-3 (operator-directed, 2026-10-07): PUT /api/apps/:app_id/listing_icon with the user token or a
# per-app token. Imitates api_listing_graphics_spec.rb. The ingest is stubbed in the success case (the repo has
# no release factory; ListingIconIngest has its own spec). NOT run (the operator said no testing).
RSpec.describe 'API listing icon', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Icon App') }
  let!(:other_app) { create(:app, name: 'Other App') }
  let(:dir) { Dir.mktmpdir }
  let(:issued) { AppApiToken.issue!(app: app, name: 'ci', created_by: owner) }

  def chunk(type, data = ''.b)
    [ data.bytesize ].pack('N') + type.b + data.b + [ Zlib.crc32(type.b + data.b) ].pack('N')
  end

  def png(width: 512, height: 512)
    ihdr = [ width, height, 8, 6, 0, 0, 0 ].pack('NNCCCCC')
    ListingGraphicInspector::PNG_SIGNATURE + chunk('IHDR', ihdr) + chunk('IDAT', 'x') + chunk('IEND')
  end

  def upload(bytes = png)
    path = File.join(dir, 'icon.png')
    File.binwrite(path, bytes)
    Rack::Test::UploadedFile.new(path, 'image/png')
  end

  def put_icon(target = app, secret: nil, **params)
    put "/api/apps/#{target.id}/listing_icon", params: params, headers: secret ? { 'Authorization' => "Bearer #{secret}" } : {}
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  after { FileUtils.remove_entry(dir) }

  it 'refuses a call with no credential' do
    put_icon(file: upload)

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'refuses a wrong zpa_ secret and does not fall back to the user token' do
    put_icon(secret: "#{AppApiToken::PREFIX}wrong", token: owner.token, file: upload)

    expect(response).to have_http_status(:unauthorized)
  end

  it 'refuses a valid token for another app (403)' do
    put_icon(other_app, secret: issued.secret, file: upload)

    expect(response).to have_http_status(:forbidden)
  end

  it 'answers 422 when no file is sent' do
    put_icon(secret: issued.secret)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to be_present
  end

  it 'answers 422 and says why when the app has no release yet' do
    put_icon(secret: issued.secret, file: upload)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['error']).to include('no published release')
  end

  it 'replaces the icon with the per-app token and reports the release' do
    release = instance_double(Release, id: 9, release_version: '1.1.4', icon_sha256: 'a' * 64,
                                       icon_download_url: 'https://zealot.example/download/releases/9/icon')
    allow(ListingIconIngest).to receive(:call).and_return(ListingIconIngest::Result.new(release: release, violations: []))

    put_icon(secret: issued.secret, file: upload)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig('icon', 'release_id')).to eq(9)
    expect(response.parsed_body.dig('icon', 'sha256')).to eq('a' * 64)
    expect(response.parsed_body['fitted']).to be(false)
  end
end
