# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Email preferences', type: :request do
  let(:user) do
    User.create!(email: 'pref@example.com', username: 'pref', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end

  it 'shows the page for a valid token without logging in' do
    get email_preferences_path(user.email_preferences_token)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('email_preferences[campaigns]')
  end

  it 'saves the choices' do
    patch email_preferences_path(user.email_preferences_token),
          params: { email_preferences: { deploys: '1', notices: '0', campaigns: '0' } }

    expect(response).to have_http_status(:see_other)
    user.reload
    expect([user.email_deploys, user.email_notices, user.email_campaigns]).to eq([true, false, false])
  end

  it '404s an invalid token' do
    get email_preferences_path('not-a-token')

    expect(response).to have_http_status(:not_found)
  end
end
