# frozen_string_literal: true

require 'rails_helper'

# Z-P11 (Play Console parity): a release's deobfuscation files (R8/ProGuard mapping, native symbols).
# Written-not-run in the sandbox (no Postgres or bundle); it imitates api_app_store_listing_spec.rb. Look
# here first if CI is red for this slice.
RSpec.describe 'Release debug symbols', type: :request do
  let(:password) { 'correct-horse-9' }

  let!(:app) { create(:app, name: 'Symbols App') }
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }
  let!(:release) do
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.0',
                build_version: '1').tap { |r| r.save!(validate: false) }
  end

  def make_user(email, role = :developer)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  def upload_file(name, body = "com.example.Main -> a.b:\n")
    file = Tempfile.new([name, '.txt'])
    file.write(body)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: name)
  end

  before do
    Zealot::TenantRegistry.reset!
    allow(CatalogIndexPublishJob).to receive(:perform_later)
    allow(ReleaseStorageCleanupJob).to receive(:perform_later)
    app.collaborators.where(owner: true).destroy_all
    app.create_owner(developer)
  end

  let!(:developer) { make_user('dev@example.com') }
  let!(:other) { make_user('other@example.com') }

  describe 'POST an API debug symbol (user token)' do
    it 'refuses a request with no token' do
      post "/api/releases/#{release.id}/debug_symbols", params: { debug_symbol: { kind: 'mapping' } }

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'stores a mapping and answers with its checksum' do
      post "/api/releases/#{release.id}/debug_symbols",
           params: { token: developer.token, debug_symbol: { kind: 'mapping', file: upload_file('mapping.txt') } }

      expect(response).to have_http_status(:created)
      stored = DebugSymbol.mapping_for(release)
      expect(stored.kind).to eq('mapping')
      expect(stored.checksum).to be_present
    end

    it 'replaces rather than appends when the same kind is uploaded again' do
      post "/api/releases/#{release.id}/debug_symbols",
           params: { token: developer.token, debug_symbol: { kind: 'mapping', file: upload_file('mapping.txt') } }
      post "/api/releases/#{release.id}/debug_symbols",
           params: { token: developer.token, debug_symbol: { kind: 'mapping', file: upload_file('mapping.txt', "other -> z:\n") } }

      expect(release.debug_symbols.where(kind: 'mapping').count).to eq(1)
    end

    it 'refuses a user who is neither the owner nor an admin' do
      post "/api/releases/#{release.id}/debug_symbols",
           params: { token: other.token, debug_symbol: { kind: 'mapping', file: upload_file('mapping.txt') } }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'the console upload' do
    before { sign_in developer }

    it 'adds a native symbol file' do
      post "/channels/#{channel.id}/releases/#{release.id}/debug_symbols",
           params: { debug_symbol: { kind: 'native_symbols', file: upload_file('symbols.zip') } }

      expect(release.debug_symbols.where(kind: 'native_symbols').count).to eq(1)
    end

    it 'removes one on request' do
      post "/channels/#{channel.id}/releases/#{release.id}/debug_symbols",
           params: { debug_symbol: { kind: 'mapping', file: upload_file('mapping.txt') } }
      symbol = DebugSymbol.mapping_for(release)

      delete "/channels/#{channel.id}/releases/#{release.id}/debug_symbols/#{symbol.id}"

      expect(DebugSymbol.exists?(symbol.id)).to be(false)
    end
  end

  describe 'the download' do
    it 'is a 404 once the row is gone' do
      get "/download/debug_symbols/0"

      expect(response).to have_http_status(:not_found)
    end
  end
end
