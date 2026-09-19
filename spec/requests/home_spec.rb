# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Landing page', type: :request do
  it 'has a single Get started button that goes to the login page' do
    get root_path

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include('landing-cta')
    expect(body).to include(%(href="#{new_user_session_path}"))
    expect(body).not_to include('/users/sign_up')
    expect(body.scan('d-btn-lg').size).to eq(1)
  end
end
