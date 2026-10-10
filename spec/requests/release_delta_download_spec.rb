# frozen_string_literal: true

require 'rails_helper'
require 'tmpdir'

# Z-P13: GET /download/releases/:id/delta?from=<version_code>. Written, NOT run in the sandbox that wrote
# it (no Rails boot or database there). It pins the route, the manifest lookup (exact then semver), and the
# two ways the bytes are served (local file, signed redirect), plus the honest 404 when there is no patch.
RSpec.describe 'Release update delta URL', type: :request do
  let(:tmp) { Dir.mktmpdir }
  let(:patch_path) { File.join(tmp, 'patch.gfb').tap { |p| File.binwrite(p, "GFbFv1_0\x00patch-bytes") } }

  def make_release
    app = create(:app)
    scheme = app.schemes.create!(name: 'Main')
    channel = scheme.channels.create!(name: 'Android', device_type: :android, slug: 'default-android')
    Release.new(channel: channel, version: 2, changelog: [], release_version: '1.1.0', build_version: '200').tap do |r|
      r.save!(validate: false)
    end
  end

  let(:release) { make_release }

  before do
    Zealot::TenantRegistry.reset!
    allow(Zealot::TenantResolver).to receive(:base_domain).and_return(nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('zealot.example.org')
  end

  after { FileUtils.remove_entry(tmp) }

  def record_patch(key)
    release.update_columns(delta_patches: [{
      'from_release_id' => 1, 'from_version_code' => '100', 'storage_key' => key,
      'size' => 17, 'format' => 'GFbFv1_0'
    }])
  end

  it 'routes to the delta action, not the filename route' do
    expect(delta_download_release_path(release, from: '100'))
      .to eq("/download/releases/#{release.id}/delta?from=100")
    expect(Rails.application.routes.recognize_path(delta_download_release_path(release, from: '100')))
      .to include(controller: 'download/releases', action: 'delta')
  end

  it 'serves the stored patch as an attachment with no login' do
    storage = instance_double(ReleaseStorage, url_for: nil, fetch: patch_path)
    allow(ReleaseStorage).to receive(:new).and_return(storage)
    allow(storage).to receive(:fetch).and_return(patch_path)

    record_patch('uploads/apps/a1/r2/pipeline/delta-from-100.gfb')
    get delta_download_release_path(release, from: '100')

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/octet-stream')
    expect(response.body.b).to start_with('GFbFv1_0'.b)
  end

  it 'redirects to a signed URL when the adapter can mint one (no local copy)' do
    storage = instance_double(ReleaseStorage, url_for: 'https://cdn.test/signed-patch')
    allow(ReleaseStorage).to receive(:new).and_return(storage)

    record_patch('uploads/apps/a1/r2/pipeline/delta-from-100.gfb')
    get delta_download_release_path(release, from: '100')

    expect(response).to have_http_status(:found)
    expect(response.headers['Location']).to eq('https://cdn.test/signed-patch')
    expect(response.headers['Cache-Control']).to eq('no-store')
  end

  it 'finds the patch by a normalised version code' do
    storage = instance_double(ReleaseStorage, url_for: nil, fetch: patch_path)
    allow(ReleaseStorage).to receive(:new).and_return(storage)
    allow(storage).to receive(:fetch).and_return(patch_path)

    release.update_columns(delta_patches: [{
      'from_release_id' => 1, 'from_version_code' => '1.2.0', 'storage_key' => 'k.gfb',
      'size' => 17, 'format' => 'GFbFv1_0'
    }])
    get delta_download_release_path(release, from: '1.2')

    expect(response).to have_http_status(:ok)
  end

  it 'is a 404 when the release has no patch from that version' do
    record_patch('k.gfb')
    get delta_download_release_path(release, from: '999')

    expect(response).to have_http_status(:not_found)
  end

  it 'is a 404 when a release has no deltas at all' do
    get delta_download_release_path(release, from: '100')
    expect(response).to have_http_status(:not_found)
  end
end
