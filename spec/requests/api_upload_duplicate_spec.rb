# frozen_string_literal: true

require 'rails_helper'

# Task 29 (D-Store leaf 7.a.v.zi): a duplicate upload is refused with 409. A real .aab fixture is not carried
# by this repo, so the manifest values are stubbed on the parser the controller built; the refusal itself
# (an existing release, a 409, no new row) is real. Written by imitating api_app_token_upload_spec.rb; NOT
# run (the standing operator instruction is no testing).
RSpec.describe 'API upload duplicate refusal', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Dup App') }
  let!(:channel) { make_channel(app) }

  def make_channel(target)
    scheme = target.schemes.create!(name: "Scheme #{target.name}")
    scheme.channels.create!(name: "Channel #{target.name}", device_type: :android)
  end

  def make_release(**attributes)
    release = channel.releases.build(release_version: '1.0.0', build_version: '1', bundle_id: 'com.example.app')
    release.save!(validate: false)
    release.update!(**attributes) if attributes.any?
    release
  end

  # A stub parser whose identity values the test controls; `AppInfo.parse` is what the controller calls. It
  # is a null object so the success path (which reads name/release_type/device off the parser) never trips an
  # unexpected-message error on a method this leaf does not care about.
  def stub_parser(bundle_id:, release_version:, build_version:)
    parser = double('AppInfo parser').as_null_object
    allow(parser).to receive(:platform).and_return('android')
    allow(parser).to receive(:bundle_id).and_return(bundle_id)
    allow(parser).to receive(:release_version).and_return(release_version)
    allow(parser).to receive(:build_version).and_return(build_version)
    allow(AppInfo).to receive(:parse).and_return(parser)
    parser
  end

  def upload_file
    file = Tempfile.new(['bundle', '.aab'])
    file.binmode
    file.write('not a real zip')
    file.flush
    Rack::Test::UploadedFile.new(file.path, 'application/octet-stream', true, original_filename: 'bundle.aab')
  end

  before do
    Zealot::TenantRegistry.reset!
    app.create_owner(owner)
  end

  it 'refuses a version Zealot already holds, with 409 and the existing release id' do
    existing = make_release
    stub_parser(bundle_id: 'com.example.app', release_version: '1.0.0', build_version: '1')

    expect do
      post '/api/apps/upload', params: { token: owner.token, channel_key: channel.key, file: upload_file }
    end.not_to change(Release, :count)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['release_id']).to eq(existing.id)
  end

  it 'does not refuse a version that is not held yet' do
    make_release
    stub_parser(bundle_id: 'com.example.app', release_version: '2.0.0', build_version: '2')

    post '/api/apps/upload', params: { token: owner.token, channel_key: channel.key, file: upload_file }

    # It gets past the duplicate gate; whether the (fake) bundle then uploads is not this leaf's concern,
    # so only the absence of a 409 is asserted.
    expect(response).not_to have_http_status(:conflict)
  end
end
