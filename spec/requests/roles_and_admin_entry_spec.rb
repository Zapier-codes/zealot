# frozen_string_literal: true

require 'rails_helper'

# Task 15: everyone who registers is a developer; the one admin email can only
# be created as admin through the /admin login entry.
RSpec.describe 'Registration roles and admin entry', type: :request do
  let(:password) { 'correct-horse-9' }
  let(:admin_email) { User.admin_signup_email }

  def log_in(email:, password:, admin_entry: false)
    params = { user: { email: email, password: password } }
    params[:admin_entry] = '1' if admin_entry
    post user_session_path, params: params
  end

  it 'registers ordinary users as developers' do
    log_in(email: 'dev@example.com', password: password)

    expect(User.find_by!(email: 'dev@example.com')).to be_developer
  end

  it 'defaults the admin email to bossblingzs@gmail.com' do
    expect(User.admin_signup_email).to eq('bossblingzs@gmail.com')
  end

  it 'never creates the admin email from the normal login page' do
    expect { log_in(email: admin_email, password: password) }.not_to change(User, :count)
  end

  it 'creates the admin account from the /admin entry and lands in the admin area' do
    expect { log_in(email: admin_email, password: password, admin_entry: true) }.to change(User, :count).by(1)

    user = User.find_by!(email: admin_email)
    expect(user).to be_admin
    expect(response).to redirect_to(admin_root_path)
  end

  it 'never makes any other email an admin, and creates nothing for them at /admin' do
    expect { log_in(email: 'someone@example.com', password: password, admin_entry: true) }
      .not_to change(User, :count)
  end

  it 'does not promote an existing account with the admin email' do
    User.create!(email: admin_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :developer)

    log_in(email: admin_email, password: password, admin_entry: true)

    expect(User.find_by!(email: admin_email)).to be_developer
  end

  it 'creates the admin even when ordinary registrations are closed' do
    allow(Setting).to receive(:registrations_enabled).and_return(false)

    expect { log_in(email: admin_email, password: password, admin_entry: true) }.to change(User, :count).by(1)
  end

  it 'shows the login form at /admin when signed out, marked as the admin entry' do
    get '/admin'

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="admin_entry"')
  end

  it '404s /admin for a signed-in developer' do
    log_in(email: 'dev@example.com', password: password)

    status = begin
      get '/admin'
      response.status
    rescue ActionController::RoutingError
      404 # test env may raise instead of rendering the 404 page
    end

    expect(status).to eq(404)
  end
end
