# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NovuDeliveryJob, type: :job do
  include ActiveJob::TestHelper

  let(:user) do
    User.create!(email: 'dev@example.com', username: 'dev', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current,
                 role: :developer, locale: 'en')
  end

  def perform(kind: 'notices')
    described_class.perform_now('zealot-notice', user.id, kind, { 'subject' => 'Hi' }, 'tx-1')
  end

  it 'triggers the workflow for the user as a Novu subscriber' do
    expect(NovuClient).to receive(:trigger).with(
      workflow_id: 'zealot-notice',
      to: { subscriberId: "zealot-#{user.id}", email: 'dev@example.com', firstName: 'dev', locale: 'en' },
      payload: { 'subject' => 'Hi' },
      transaction_id: 'tx-1'
    )

    perform
  end

  it 'skips a user who opted out in the meantime' do
    user.update_columns(email_notices: false)

    expect(NovuClient).not_to receive(:trigger)
    perform
  end

  it 'skips a locked user' do
    user.update_columns(locked_at: Time.current)

    expect(NovuClient).not_to receive(:trigger)
    perform
  end

  it 'retries temporary Novu failures' do
    allow(NovuClient).to receive(:trigger).and_raise(NovuClient::TemporaryError, 'Novu 503')

    expect { perform }.to have_enqueued_job(described_class)
  end

  it 'gives up quietly on permanent failures' do
    allow(NovuClient).to receive(:trigger).and_raise(NovuClient::PermanentError, 'Novu 401')

    expect { perform }.not_to raise_error
    expect(enqueued_jobs).to be_empty
  end
end
