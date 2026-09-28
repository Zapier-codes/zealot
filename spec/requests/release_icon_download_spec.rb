# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Task 27d-b: GET /download/releases/:id/icon. NOT run in the sandbox that wrote it (no Rails boot or
# database there).
RSpec.describe 'Release icon URL', type: :request do
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:tmp) { Dir.mktmpdir }
  let(:icon_path) { File.join(tmp, 'icon.png').tap { |path| File.binwrite(path, "\x89PNG-bytes") } }

  def make_channel(app, slug)
    scheme = app.schemes.create!(name: 'Main')
    scheme.channels.create!(name: 'Android', device_type: :android, slug: slug)
  end

  def make_release(channel)
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                build_version: '1').tap { |release| release.save!(validate: false) }
  end

  let(:release) { make_release(make_channel(create(:app), 'default-android')) }

  before do
    Zealot::TenantRegistry.reset!
    allow(Zealot::TenantResolver).to receive(:base_domain).and_return(nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('zealot.example.org')
  end

  after { FileUtils.remove_entry(tmp) }

  it 'routes /download/releases/:id/icon to the icon action, not the filename route' do
    expect(icon_download_release_path(release)).to eq("/download/releases/#{release.id}/icon")
    expect(Rails.application.routes.recognize_path(icon_download_release_path(release)))
      .to include(controller: 'download/releases', action: 'icon')
    expect(Rails.application.routes.recognize_path("/download/releases/#{release.id}/app.apk"))
      .to include(controller: 'download/releases', action: 'download', filename: 'app.apk')
  end

  it 'serves the local icon inline with an image type, with no login' do
    allow_any_instance_of(Release).to receive(:icon).and_return(double(path: icon_path))

    get icon_download_release_path(release)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
    expect(response.headers['Content-Disposition']).to start_with('inline')
    expect(response.body.b).to eq("\x89PNG-bytes".b)
  end

  it 'redirects to the mirrored copy when there is no local icon (after a redeploy)' do
    release.update_columns(icon_storage_key: "uploads/apps/a#{release.app.id}/r#{release.id}/icons/icon.png")
    storage = instance_double(ReleaseStorage, url_for: 'https://cdn.test/signed-icon')
    allow(ReleaseStorage).to receive(:new).and_return(storage)

    get icon_download_release_path(release)

    expect(response).to have_http_status(:found)
    expect(response.location).to eq('https://cdn.test/signed-icon')
    expect(response.headers['Cache-Control']).to include('no-store')
  end

  it 'is a 404 when the release has no icon anywhere' do
    get icon_download_release_path(release)

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to have_key('error')
  end

  it 'is a 404 for a release id that does not exist' do
    get '/download/releases/0/icon'

    expect(response).to have_http_status(:not_found)
  end

  it 'does not fire the download web hook' do
    allow_any_instance_of(Release).to receive(:icon).and_return(double(path: icon_path))
    expect_any_instance_of(Channel).not_to receive(:perform_web_hook)

    get icon_download_release_path(release)
  end

  describe 'canonical host (same rule as the release page)' do
    let(:release) { make_release(make_channel(create(:app, tenant: acme), 'acme-android')) }

    it 'redirects a GET on the wrong host to the owning tenant host' do
      get icon_download_release_path(release)

      expect(response).to have_http_status(:found)
      expect(response.location).to eq("http://store.acme.example.com/download/releases/#{release.id}/icon")
    end
  end
end
