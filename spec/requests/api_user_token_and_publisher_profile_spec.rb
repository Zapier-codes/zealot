# frozen_string_literal: true

require 'rails_helper'

# Task 42j: a platform admin reads any account's API token, and the publisher profile over the API. User token
# only, in `params[:token]` (the legacy door). NOT run (no Postgres or gems in the sandbox that wrote it).
RSpec.describe 'API user token and publisher profile', type: :request do
  let(:password) { 'correct-horse-9' }

  def make_user(email, role)
    User.create!(email: email, username: email.split('@').first, password: password,
                 password_confirmation: password, confirmed_at: Time.current).tap { |u| u.update!(role: role) }
  end

  let!(:admin) { make_user('boss@example.com', :admin) }
  let!(:developer) { make_user('dev@example.com', :developer) }
  let!(:other) { make_user('other@example.com', :developer) }

  def as(user, extra = {})
    { token: user.token }.merge(extra)
  end

  let(:profile_params) do
    { kind: 'individual', display_name: 'Ada Labs', legal_name: 'Ada Lovelace', country: 'Nigeria',
      contact_email: 'ada@example.com' }
  end

  describe 'GET /api/users/:id/token' do
    it 'gives a platform admin any account\'s token' do
      get "/api/users/#{developer.id}/token", params: as(admin)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq('user_id' => developer.id, 'email' => 'dev@example.com',
                                         'token' => developer.token)
    end

    it 'is refused for anyone who is not a platform admin, even for their own account' do
      get "/api/users/#{developer.id}/token", params: as(developer)
      expect(response).to have_http_status(:forbidden)
      expect(response.body).not_to include(developer.token)

      get "/api/users/#{other.id}/token", params: as(developer)
      expect(response).to have_http_status(:forbidden)
    end

    it 'is a 404 for no such user and never leaks the token in the user record' do
      get '/api/users/0/token', params: as(admin)
      expect(response).to have_http_status(:not_found)

      get "/api/users/#{developer.id}", params: as(admin)
      expect(response.body).not_to include(developer.token)
    end

    it 'can be found by email through the existing admin search' do
      get '/api/users/search', params: as(admin, email: 'dev@example.com')
      expect(response.parsed_body['id']).to eq(developer.id)
    end
  end

  describe 'the token\'s own publisher profile' do
    it 'is a 404 until one exists' do
      get '/api/publisher_profile', params: as(developer)
      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body['code']).to eq('publisher_profile_missing')
    end

    it 'creates it (201), then changes it (200)' do
      put '/api/publisher_profile', params: as(developer, profile_params)
      expect(response).to have_http_status(:created)
      expect(developer.reload.publisher_profile).to have_attributes(kind: 'individual', display_name: 'Ada Labs')

      put '/api/publisher_profile', params: as(developer, display_name: 'Ada Studio')
      expect(response).to have_http_status(:ok)
      expect(developer.reload.publisher_profile.display_name).to eq('Ada Studio')

      get '/api/publisher_profile', params: as(developer)
      expect(response.parsed_body).to include('display_name' => 'Ada Studio', 'user_id' => developer.id)
    end

    it 'accepts the fields inside publisher_profile too' do
      put '/api/publisher_profile', params: as(developer, publisher_profile: profile_params)
      expect(response).to have_http_status(:created)
    end

    it 'answers 422 with the field errors when it is not valid' do
      put '/api/publisher_profile', params: as(developer, profile_params.merge(contact_email: 'nope', kind: 'bogus'))

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['code']).to eq('publisher_profile_invalid')
      expect(response.parsed_body['errors']).to include('contact_email')
      expect(developer.reload.publisher_profile).to be_nil
    end
  end

  describe 'another account\'s publisher profile' do
    it 'lets a platform admin create and read it' do
      put "/api/users/#{developer.id}/publisher_profile", params: as(admin, profile_params)
      expect(response).to have_http_status(:created)
      expect(developer.reload.publisher_profile).to be_present
      expect(admin.reload.publisher_profile).to be_nil

      get "/api/users/#{developer.id}/publisher_profile", params: as(admin)
      expect(response.parsed_body['user_id']).to eq(developer.id)
    end

    it 'is refused (403) for a non-admin naming someone else, and changes nothing' do
      put "/api/users/#{other.id}/publisher_profile", params: as(developer, profile_params)

      expect(response).to have_http_status(:forbidden)
      expect(other.reload.publisher_profile).to be_nil
      expect(developer.reload.publisher_profile).to be_nil
    end
  end
end
