# frozen_string_literal: true

require 'rails_helper'

# Task 34d-1 (D-Store leaf 35, `7.a.xi.zi`): the org-wide Android signing key over the API. Platform admins
# only, user token in the Authorization header only. Written by imitating api_listing_edit_spec.rb;
# NOT run (the operator said no testing), so it is the first thing to look at if CI is red for this slice.
# The keytool check is stubbed: the CI image need not carry a JDK.
RSpec.describe 'API Android signing key', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:keystore_bytes) { "fake-keystore-bytes-\xFF\x00\x01".b }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap do |user|
      user.update!(role: role)
    end
  end

  let!(:admin) { make_user('admin@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }

  let(:path) { '/api/android_signing_key' }

  def bearer(secret)
    { 'Authorization' => "Bearer #{secret}" }
  end

  def as(user)
    bearer(user.token)
  end

  def keystore_upload(bytes = keystore_bytes)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), 'application/octet-stream', true,
                                 original_filename: 'release.jks')
  end

  def key_params(**overrides)
    { keystore: keystore_upload, key_alias: 'release', keystore_password: 'store-pass-1',
      key_password: 'key-pass-1' }.merge(overrides)
  end

  def create_key
    allow(Anthropic::ApkSigningService).to receive(:verify_keystore!)
    post path, params: key_params, headers: as(admin)
    expect(response).to have_http_status(:created)
  end

  before { Zealot::TenantRegistry.reset! }

  describe 'who may call' do
    it 'refuses every action with no credential' do
      get path
      expect(response).to have_http_status(:unauthorized)
      post path, params: key_params
      expect(response).to have_http_status(:unauthorized)
      delete path
      expect(response).to have_http_status(:unauthorized)
      expect(AndroidSigningKey.count).to eq(0)
    end

    it 'does not read the user token from the query string or the body' do
      get path, params: { token: admin.token }
      expect(response).to have_http_status(:unauthorized)
      post path, params: key_params(token: admin.token)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a per-app token, even a well-formed one' do
      get path, headers: bearer("#{AppApiToken::PREFIX}#{'a' * AppApiToken::SECRET_BODY_LENGTH}")
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses an admin whose account is locked' do
      admin.update!(locked_at: Time.current)
      get path, headers: as(admin)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'refuses a developer with 403, and answers the same whether or not a key exists' do
      get path, headers: as(developer)
      without_key = response.status
      create_key
      get path, headers: as(developer)

      expect(without_key).to eq(403)
      expect(response).to have_http_status(:forbidden)
      post path, params: key_params, headers: as(developer)
      expect(response).to have_http_status(:forbidden)
      delete path, params: { checksum: AndroidSigningKey.current.checksum }, headers: as(developer)
      expect(response).to have_http_status(:forbidden)
      expect(AndroidSigningKey.count).to eq(1)
    end
  end

  describe 'GET /api/android_signing_key' do
    it 'is 404 when no key is configured' do
      get path, headers: as(admin)
      expect(response).to have_http_status(:not_found)
    end

    it 'returns the metadata and never the keystore or a password' do
      create_key
      get path, headers: as(admin)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body.keys).to match_array(%w[id filename key_alias checksum created_at])
      expect(body['filename']).to eq('release.jks')
      expect(body['key_alias']).to eq('release')
      expect(body['checksum']).to eq(Digest::SHA1.hexdigest(keystore_bytes))
      expect(response.body).not_to include('store-pass-1')
      expect(response.body).not_to include('key-pass-1')
    end
  end

  describe 'POST /api/android_signing_key' do
    before { allow(Anthropic::ApkSigningService).to receive(:verify_keystore!) }

    it 'stores the key, checks it with keytool and answers 201 with metadata only' do
      post path, params: key_params, headers: as(admin)

      expect(response).to have_http_status(:created)
      expect(Anthropic::ApkSigningService).to have_received(:verify_keystore!).with(
        keystore_bytes: keystore_bytes, keystore_password: 'store-pass-1',
        key_alias: 'release', key_password: 'key-pass-1'
      )
      key = AndroidSigningKey.current
      expect(key.keystore.b).to eq(keystore_bytes)
      expect(key.key_password).to eq('key-pass-1')
      expect(response.body).not_to include('store-pass-1')
    end

    it 'refuses a second key with 409 and keeps the first' do
      create_key
      first_checksum = AndroidSigningKey.current.checksum

      post path, params: key_params(keystore: keystore_upload('another keystore'.b)), headers: as(admin)

      expect(response).to have_http_status(:conflict)
      expect(AndroidSigningKey.count).to eq(1)
      expect(AndroidSigningKey.current.checksum).to eq(first_checksum)
    end

    it 'refuses a request with no keystore file (422)' do
      post path, params: key_params(keystore: nil), headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      post path, params: key_params(keystore: 'not a file'), headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(AndroidSigningKey.count).to eq(0)
    end

    it 'refuses a keystore over the size cap (413)' do
      stub_const('Api::AndroidSigningKeysController::MAX_KEYSTORE_BYTES', 8)
      post path, params: key_params, headers: as(admin)
      expect(response).to have_http_status(413)
      expect(AndroidSigningKey.count).to eq(0)
    end

    it 'refuses a missing alias or password (422, with the field named)' do
      post path, params: key_params(key_alias: ''), headers: as(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['entry']).to have_key('key_alias')
      expect(AndroidSigningKey.count).to eq(0)
    end

    it 'refuses a keystore that keytool cannot open (422) and saves nothing' do
      allow(Anthropic::ApkSigningService).to receive(:verify_keystore!)
        .and_raise(Anthropic::ApkSigningService::InvalidKeystoreError, 'keystore verification failed: bad password')

      post path, params: key_params, headers: as(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AndroidSigningKey.count).to eq(0)
    end

    it 'answers 503 and saves nothing when keytool is not installed' do
      allow(Anthropic::ApkSigningService).to receive(:verify_keystore!)
        .and_raise(Anthropic::ApkSigningService::KeytoolNotFoundError, 'keytool not found')

      post path, params: key_params, headers: as(admin)

      expect(response).to have_http_status(:service_unavailable)
      expect(AndroidSigningKey.count).to eq(0)
    end
  end

  describe 'DELETE /api/android_signing_key' do
    it 'refuses to remove the key without its checksum, or with another one (409)' do
      create_key

      delete path, headers: as(admin)
      expect(response).to have_http_status(:conflict)
      delete path, params: { checksum: 'deadbeef' }, headers: as(admin)
      expect(response).to have_http_status(:conflict)
      expect(AndroidSigningKey.count).to eq(1)
    end

    it 'removes the key when the checksum matches (202), after which a new one can be added' do
      create_key

      delete path, params: { checksum: AndroidSigningKey.current.checksum }, headers: as(admin)

      expect(response).to have_http_status(:accepted)
      expect(AndroidSigningKey.count).to eq(0)
      create_key
    end

    it 'is 404 when there is no key' do
      delete path, params: { checksum: 'x' }, headers: as(admin)
      expect(response).to have_http_status(:not_found)
    end
  end
end
