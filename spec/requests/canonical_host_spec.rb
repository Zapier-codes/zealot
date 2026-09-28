# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7b: a channel's public pages and downloads redirect (302) to the owning tenant's
# host when asked for on another host. Same tenant, default-on-default, non-GET and "no usable
# host" are all untouched. NOT run in the sandbox that wrote it (no Rails boot or database there).
RSpec.describe 'Canonical host redirect', type: :request do
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:globex) { create(:tenant, tenant_id: 'globex', domains: ['store.globex.example.com']) }
  let(:bare) { create(:tenant, tenant_id: 'bare', domains: []) }

  def make_channel(app, slug)
    scheme = app.schemes.create!(name: 'Main')
    scheme.channels.create!(name: 'Android', device_type: :android, slug: slug)
  end

  def make_release(channel)
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                build_version: '1').tap { |release| release.save!(validate: false) }
  end

  let!(:acme_channel) { make_channel(create(:app, tenant: acme), 'acme-android') }
  let!(:default_channel) { make_channel(create(:app), 'default-android') }
  let!(:bare_channel) { make_channel(create(:app, tenant: bare), 'bare-android') }

  before do
    Zealot::TenantRegistry.reset!
    allow(Zealot::TenantResolver).to receive(:base_domain).and_return(nil)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('ZEALOT_DOMAIN').and_return('zealot.example.org')
  end

  it 'sends a shared install link on the wrong host to the owning tenant\'s host' do
    get friendly_channel_releases_path(acme_channel)

    expect(response).to have_http_status(:found)
    expect(response.location).to eq('http://store.acme.example.com/acme-android')
  end

  it 'keeps the query string' do
    get friendly_channel_releases_path(acme_channel), params: { back_url: '/somewhere' }

    expect(response.location).to eq('http://store.acme.example.com/acme-android?back_url=%2Fsomewhere')
  end

  it 'also redirects the release page and the channel overview' do
    release = make_release(acme_channel)

    get friendly_channel_release_path(acme_channel, release)
    expect(response.location).to start_with('http://store.acme.example.com/acme-android/')

    get friendly_channel_overview_path(acme_channel)
    expect(response.location).to start_with('http://store.acme.example.com/')
  end

  it 'redirects a release download asked for on the wrong host' do
    release = make_release(acme_channel)

    get download_release_path(release)

    expect(response).to have_http_status(:found)
    expect(response.location).to eq("http://store.acme.example.com/download/releases/#{release.id}")
  end

  it 'does not redirect on the owning tenant\'s own host' do
    host! 'store.acme.example.com'

    get friendly_channel_releases_path(acme_channel)

    expect(response.location.to_s).not_to include('//www.example.com')
    expect(response.location.to_s).not_to include('zealot.example.org')
  end

  it 'sends a default-tenant channel asked for on a tenant\'s host to the default host' do
    host! 'store.globex.example.com'
    globex

    get friendly_channel_releases_path(default_channel)

    expect(response).to have_http_status(:found)
    expect(response.location).to eq('http://zealot.example.org/default-android')
  end

  it 'leaves the default tenant\'s links on the default host alone' do
    get friendly_channel_releases_path(default_channel)

    expect(response.location.to_s).not_to include('zealot.example.org')
    expect(response.location.to_s).not_to include('store.')
  end

  it 'sends another tenant\'s channel to its own host, not the request\'s' do
    host! 'store.globex.example.com'
    globex

    get friendly_channel_releases_path(acme_channel)

    expect(response.location).to eq('http://store.acme.example.com/acme-android')
  end

  it 'does not redirect when the owning tenant has no usable host (fails open)' do
    get friendly_channel_releases_path(bare_channel)

    expect(response.location.to_s).not_to include('bare')
    expect(response.location.to_s).not_to start_with('http://store.')
  end

  it 'never redirects a non-GET request' do
    delete friendly_channel_version_path(acme_channel, '1.0.0')

    expect(response.location.to_s).not_to include('store.acme.example.com')
  end
end
