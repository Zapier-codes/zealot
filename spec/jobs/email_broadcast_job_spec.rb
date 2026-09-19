# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailBroadcastJob, type: :job do
  include ActiveJob::TestHelper

  def create_user(email, **attrs)
    User.create!({ email: email, username: email.split('@').first, password: 'correct-horse-9',
                   password_confirmation: 'correct-horse-9', confirmed_at: Time.current,
                   role: :developer }.merge(attrs))
  end

  before do
    create_user('one@example.com')
    create_user('two@example.com', email_campaigns: false)
  end

  it 'queues one campaign email per opted-in user' do
    expect do
      described_class.perform_now(kind: 'campaigns', subject: 'News', body: 'Hi')
    end.to have_enqueued_mail(NotificationMailer, :campaign).once
  end

  it 'queues notices for users who kept notices on' do
    expect do
      described_class.perform_now(kind: 'notices', subject: 'Maintenance', body: 'Tonight')
    end.to have_enqueued_mail(NotificationMailer, :notice).twice
  end

  it 'sends nothing when notifications are switched off' do
    allow(EmailNotifications).to receive(:enabled?).and_return(false)

    expect do
      described_class.perform_now(kind: 'campaigns', subject: 'News', body: 'Hi')
    end.not_to have_enqueued_mail
  end

  it 'refuses unknown kinds' do
    expect do
      described_class.perform_now(kind: 'receipts', subject: 's', body: 'b')
    end.to raise_error(ArgumentError)
  end
end
