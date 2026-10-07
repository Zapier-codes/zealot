# frozen_string_literal: true

require 'rails_helper'

# Task 43b-2 / 43b-4 (NOT run; the operator said no testing): the console half of the publish gate. The page shows
# what is missing and disables the two buttons; the request and pay actions redirect back with a message.
RSpec.describe 'Store listing publish gate in the console', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:owner) do
    User.create!(email: 'gate-owner@example.com', username: 'gateowner', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end
  let(:profile) do
    PublisherProfile.create!(user: owner, kind: :individual, display_name: 'Ada Labs', legal_name: 'Ada Lovelace',
                             country: 'Nigeria', contact_email: owner.email)
  end
  let(:app_record) { App.create!(name: 'Gate app').tap { |app| app.create_owner(owner) } }
  let(:missing) do
    [ ListingRequirements::Missing.new(key: :icon), ListingRequirements::Missing.new(key: :screenshots, count: 1, target: 2) ]
  end

  before do
    Zealot::TenantRegistry.reset!
    allow(CatalogIndexPublishJob).to receive(:perform_later)
    sign_in owner
  end

  it 'shows what is missing, links to the graphics panel and disables the publish button for a draft' do
    allow(ListingRequirements).to receive(:call).and_return(missing)

    get app_store_listing_path(app_record)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Add the store pictures first')
    expect(response.body).to include('no icon and 1 of 2 screenshots')
    expect(response.body).to include('#listing-graphics')
    expect(response.body).to match(/<button[^>]*disabled[^>]*>\s*Publish to the store/m)
  end

  it 'shows no warning and an enabled button when nothing is missing' do
    allow(ListingRequirements).to receive(:call).and_return([])

    get app_store_listing_path(app_record)

    expect(response.body).not_to include('Add the store pictures first')
    expect(response.body).not_to match(/<button[^>]*disabled[^>]*>\s*Publish to the store/m)
  end

  it 'refuses a request for an incomplete draft with a message and leaves it a draft' do
    profile
    allow(ListingRequirements).to receive(:call).and_return(missing)

    post app_store_listing_path(app_record)

    expect(response).to redirect_to(app_store_listing_path(app_record))
    expect(flash[:alert]).to include('no icon')
    expect(app_record.reload.listing_status).to eq('draft')
  end

  it 'refuses to start a payment for an incomplete listing and creates no Payment' do
    profile
    app_record.request_store_listing!(profile)
    allow(ListingRequirements).to receive(:call).and_return(missing)
    expect(StoreListingPayment).not_to receive(:start)

    post pay_app_store_listing_path(app_record)

    expect(response).to redirect_to(app_store_listing_path(app_record))
    expect(flash[:alert]).to include('no icon')
    expect(Payment.count).to eq(0)
  end
end
