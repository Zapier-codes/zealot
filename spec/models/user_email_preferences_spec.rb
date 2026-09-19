# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailPreferences do
  def create_user(email, **attrs)
    User.create!({ email: email, username: email.split('@').first, password: 'correct-horse-9',
                   password_confirmation: 'correct-horse-9', confirmed_at: Time.current,
                   role: :developer }.merge(attrs))
  end

  it 'starts every user opted in to every kind' do
    user = create_user('a@example.com')

    EmailPreferences::KINDS.each { |kind| expect(user.wants_email?(kind)).to be(true) }
  end

  it 'only returns opted-in, unlocked users' do
    opted_in = create_user('in@example.com')
    create_user('out@example.com', email_campaigns: false)
    create_user('locked@example.com', locked_at: Time.current)

    expect(User.wanting_email(:campaigns)).to contain_exactly(opted_in)
  end

  it 'rejects unknown kinds' do
    expect { User.wanting_email(:receipts) }.to raise_error(ArgumentError)
  end

  it 'round-trips the preferences token and rejects a tampered one' do
    user = create_user('t@example.com')

    expect(User.find_by_email_preferences_token(user.email_preferences_token)).to eq(user)
    expect(User.find_by_email_preferences_token("#{user.email_preferences_token}x")).to be_nil
  end
end
