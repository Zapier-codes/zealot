# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 27d-d2-d: GET /download/graphics/:id. NOT run in the sandbox that wrote it (no Rails boot or
# database there).
RSpec.describe 'Listing graphic URL', type: :request do
  let(:root) { Dir.mktmpdir }
  let(:graphic) do
    ListingGraphic.new(app: create(:app), kind: 'screenshot', device: 'phone', position: 0,
                       content_type: 'image/png', byte_size: 9, width: 1080, height: 1920)
                  .tap { |record| record.save!(validate: false) }
  end
  let(:key) { "uploads/apps/a#{graphic.app_id}/graphics/g#{graphic.id}/graphic.png" }

  before do
    allow(ReleaseStorage).to receive(:build_adapter).and_return(ReleaseStorage::LocalAdapter.new(root: root))
  end

  after { FileUtils.remove_entry(root) }

  def store_bytes
    FileUtils.mkdir_p(File.join(root, File.dirname(key)))
    File.binwrite(File.join(root, key), 'png-bytes')
    graphic.update_columns(storage_key: key)
  end

  it 'routes /download/graphics/:id to the show action' do
    expect(download_graphic_path(graphic)).to eq("/download/graphics/#{graphic.id}")
    expect(Rails.application.routes.recognize_path(download_graphic_path(graphic)))
      .to include(controller: 'download/graphics', action: 'show')
  end

  it 'serves the stored bytes inline with the recorded type and no login' do
    store_bytes

    get download_graphic_path(graphic)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
    expect(response.headers['Content-Disposition']).to start_with('inline')
    expect(response.body.b).to eq('png-bytes'.b)
  end

  it 'takes the content type from the recorded facts, not from a name' do
    store_bytes
    graphic.update_columns(content_type: 'image/jpeg')

    get download_graphic_path(graphic)

    expect(response.media_type).to eq('image/jpeg')
  end

  it 'redirects to the signed storage URL when the adapter has one, uncached' do
    graphic.update_columns(storage_key: key)
    adapter = instance_double(ReleaseStorage::LocalAdapter, url_for: 'https://cdn.test/signed-graphic')
    allow(ReleaseStorage).to receive(:build_adapter).and_return(adapter)

    get download_graphic_path(graphic)

    expect(response).to have_http_status(:found)
    expect(response.location).to eq('https://cdn.test/signed-graphic')
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'is a 404 when the graphic was never ingested' do
    get download_graphic_path(graphic)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to have_key('error')
  end

  it 'is a 404 once the bytes are gone from storage' do
    graphic.update_columns(storage_key: key)

    get download_graphic_path(graphic)

    expect(response).to have_http_status(:not_found)
  end

  it 'is a 404 for a graphic id that does not exist' do
    get '/download/graphics/0'

    expect(response).to have_http_status(:not_found)
  end

  it 'serves the same image on any host (no canonical-host redirect)' do
    store_bytes

    get download_graphic_path(graphic), headers: { 'Host' => 'store.acme.example.com' }

    expect(response).to have_http_status(:ok)
  end
end
