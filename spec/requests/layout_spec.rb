# frozen_string_literal: true

require 'rails_helper'

# Task 14f: there is no top nav anywhere. What it carried now lives in the
# sidebar (Donate, Profile, Log out, collapse toggle) and a floating drawer
# button on small screens; breadcrumbs render in the content header.
RSpec.describe 'Layout without a top nav', type: :request do
  let(:password) { 'correct-horse-9' }

  before do
    User.create!(email: 'nav@example.com', username: 'nav', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end

  it 'renders no navbar on the landing page or the login page' do
    get root_path
    expect(response.body).not_to include('d-navbar')

    get new_user_session_path
    expect(response.body).not_to include('d-navbar')
  end

  it 'keeps Profile, Log out and the drawer toggle reachable in the console' do
    post user_session_path, params: { user: { email: 'nav@example.com', password: password } }
    get dashboard_path

    body = response.body
    expect(response).to have_http_status(:ok)
    expect(body).not_to include('d-navbar')
    expect(body).to include(edit_user_registration_path)
    expect(body).to include(%(action="#{destroy_user_session_path}"))
    expect(body).to include('for="zealot-drawer"')
    expect(body).to include('global#showSponsorModal')
  end
end
