# frozen_string_literal: true

require 'rails_helper'

# The login page is the only auth page: an unknown email + password registers
# a new account, a known email logs in, and both are remembered.
# See Users::SessionsController#create (Task 14c).
RSpec.describe 'Unified login / sign-up', type: :request do
  let(:password) { 'correct-horse-9' }

  def log_in(email:, password:)
    post user_session_path, params: { user: { email: email, password: password } }
  end

  it 'registers an unknown email, signs it in and remembers it' do
    expect { log_in(email: 'Fresh.User@example.com', password: password) }.to change(User, :count).by(1)

    user = User.find_by!(email: 'fresh.user@example.com')
    expect(user.username).to eq('fresh.user')
    expect(response).to have_http_status(:found)
    expect(response.headers['Set-Cookie']).to include('remember_user_token')
  end

  it 'logs an existing user in without creating anything' do
    User.create!(email: 'known@example.com', username: 'known', password: password,
                 password_confirmation: password, confirmed_at: Time.current)

    expect { log_in(email: 'known@example.com', password: password) }.not_to change(User, :count)
    expect(response).to have_http_status(:found)
    expect(response.headers['Set-Cookie']).to include('remember_user_token')
  end

  it 'does not create or log in anything when an existing email has the wrong password' do
    User.create!(email: 'known@example.com', username: 'known', password: password,
                 password_confirmation: password, confirmed_at: Time.current)

    expect { log_in(email: 'known@example.com', password: 'wrong-password') }.not_to change(User, :count)
    expect(response.headers['Set-Cookie'].to_s).not_to include('remember_user_token')
  end

  it 'shows validation errors instead of creating an account when the password is too short' do
    expect { log_in(email: 'short@example.com', password: '123') }.not_to change(User, :count)
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'gives a second account with the same email local part a different username' do
    log_in(email: 'sam@one.example', password: password)
    delete destroy_user_session_path
    log_in(email: 'sam@two.example', password: password)

    expect(User.pluck(:username)).to contain_exactly('sam', 'sam2')
  end

  context 'when registrations are disabled' do
    before { allow(Setting).to receive(:registrations_enabled).and_return(false) }

    it 'does not register unknown emails' do
      expect { log_in(email: 'nobody@example.com', password: password) }.not_to change(User, :count)
    end
  end

  it 'no longer routes a separate sign-up page' do
    route = Rails.application.routes.recognize_path('/users/sign_up')
    expect([route[:controller], route[:action]]).not_to eq(%w[users/registrations new])
  end

  it 'keeps the profile page routes' do
    expect(edit_user_registration_path).to eq('/users/edit')
    expect(user_registration_path).to eq('/users')
  end
end
