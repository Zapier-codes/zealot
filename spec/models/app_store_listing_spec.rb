# frozen_string_literal: true

require 'rails_helper'

# Task 25: publisher profile + the app's store listing states
# (draft -> awaiting_payment -> live).
RSpec.describe 'Store listing' do
  def make_user(name)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :developer)
  end

  def make_profile(user, kind: :individual, display_name: 'Ada Labs')
    PublisherProfile.create!(user: user, kind: kind, display_name: display_name, legal_name: 'Ada Lovelace',
                             country: 'Nigeria', contact_email: user.email)
  end

  let(:user)    { make_user('ada') }
  let(:profile) { make_profile(user) }
  let(:app)     { App.create!(name: 'Listed app') }

  describe PublisherProfile do
    it 'needs the public name, legal name, country and a valid contact email' do
      bad = PublisherProfile.new(user: user)
      expect(bad).not_to be_valid
      expect(bad.errors.attribute_names).to include(:display_name, :legal_name, :country, :contact_email)

      expect(PublisherProfile.new(user: user, display_name: 'A', legal_name: 'B', country: 'C',
                                  contact_email: 'not-an-email')).not_to be_valid
    end

    it 'allows one profile per user' do
      profile
      expect { make_profile(user) }.to raise_error(ActiveRecord::RecordNotUnique).or raise_error(ActiveRecord::RecordInvalid)
    end

    it 'cannot switch kind while one of the user\'s apps is live' do
      app.update!(publisher_profile: profile, listing_status: :awaiting_payment)
      app.go_live!

      profile.kind = :company
      expect(profile).not_to be_valid
      expect(profile.errors[:kind]).to be_present
    end
  end

  describe 'moving an app through the listing states' do
    it 'starts as a draft' do
      expect(app).to be_listing_draft
    end

    it 'goes draft -> awaiting_payment only with a profile' do
      expect(app.request_store_listing!(nil)).to be false
      expect(app).to be_listing_draft

      app.request_store_listing!(profile)
      expect(app.reload).to be_listing_awaiting_payment
      expect(app.publisher_profile).to eq(profile)
    end

    it 'cannot be requested twice or skip payment' do
      app.request_store_listing!(profile)

      expect(app.request_store_listing!(profile)).to be false
      draft = App.create!(name: 'Never asked')
      expect(draft.go_live!).to be false
    end

    it 'goes live from awaiting_payment and remembers the first go-live time' do
      app.request_store_listing!(profile)
      app.go_live!
      first_time = app.reload.listed_at

      expect(app).to be_listing_live
      expect(first_time).to be_present

      app.update!(listing_status: :suspended)
      app.go_live!
      expect(app.reload.listed_at).to eq(first_time)
    end
  end

  describe '#publisher_display_name' do
    it 'prefers the alias' do
      app.update!(publisher_alias: 'Friend Co')
      app.request_store_listing!(profile)
      app.go_live!

      expect(app.publisher_display_name).to eq('Friend Co')
    end

    it 'falls back to an individual\'s public name once live, not before' do
      app.request_store_listing!(profile)
      expect(app.publisher_display_name).to be_nil

      app.go_live!
      expect(app.publisher_display_name).to eq('Ada Labs')
    end

    it 'does not show a company\'s name until company verification exists' do
      company = make_profile(make_user('acme'), kind: :company, display_name: 'Acme Ltd')
      app.request_store_listing!(company)
      app.go_live!

      expect(app.publisher_display_name).to be_nil
    end
  end
end
