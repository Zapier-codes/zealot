# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EmailNotifications do
  include ActiveJob::TestHelper

  let(:user) do
    User.create!(email: 'dev@example.com', username: 'dev', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current,
                 role: :developer, locale: 'en')
  end

  def with_env(overrides)
    stub_const('ENV', ENV.to_hash.except('NOVU_API_KEY', 'ZEALOT_EMAIL_PROVIDER').merge(overrides))
  end

  describe '.provider' do
    it 'is SMTP without a Novu key' do
      with_env({})
      expect(described_class.provider).to eq(:smtp)
    end

    it 'is Novu once NOVU_API_KEY is set' do
      with_env('NOVU_API_KEY' => 'k')
      expect(described_class.provider).to eq(:novu)
    end

    it 'can be forced back to SMTP even with a key' do
      with_env('NOVU_API_KEY' => 'k', 'ZEALOT_EMAIL_PROVIDER' => 'smtp')
      expect(described_class.provider).to eq(:smtp)
    end

    it 'is disabled when Novu is forced but has no key' do
      with_env('ZEALOT_EMAIL_PROVIDER' => 'novu')
      expect(described_class.provider).to eq(:novu)
      expect(described_class.enabled?).to be(false)
    end
  end

  describe '.configured? for SMTP in production' do
    before { allow(Rails.env).to receive(:production?).and_return(true) }

    it 'is false when SMTP_ADDRESS is unset or the literal "false" from render.yaml' do
      with_env({})
      expect(described_class.configured?).to be(false)

      with_env('SMTP_ADDRESS' => 'false')
      expect(described_class.configured?).to be(false)
    end

    it 'is true once an SMTP host is set' do
      with_env('SMTP_ADDRESS' => 'smtp.example.com')
      expect(described_class.configured?).to be(true)
    end
  end

  describe '.workflow_id' do
    it 'has defaults and can be overridden' do
      with_env('NOVU_WORKFLOW_NOTICE' => 'my-notice')

      expect(described_class.workflow_id(:notice)).to eq('my-notice')
      expect(described_class.workflow_id(:campaign)).to eq('zealot-campaign')
      expect(described_class.workflow_id(:release_deployed)).to eq('zealot-release-deployed')
    end
  end

  describe 'delivering through Novu' do
    before { with_env('NOVU_API_KEY' => 'k') }

    it 'enqueues one Novu delivery for a notice, with a per-broadcast transaction id' do
      expect do
        described_class.deliver_notice(user, subject: 'Maintenance', body: "Line one.\n\nLine two.", broadcast_id: 'b1')
      end.to have_enqueued_job(NovuDeliveryJob).with(
        'zealot-notice', user.id, 'notices', hash_including(subject: 'Maintenance'), "notice-b1-user-#{user.id}"
      )
    end

    it 'splits the body into paragraphs and links the preferences page' do
      payload = described_class.broadcast_payload(user, :campaigns, 'News', "One.\n\nTwo.\n")

      expect(payload[:paragraphs]).to eq(%w[One. Two.])
      expect(payload[:body]).to eq("One.\n\nTwo.\n")
      expect(payload[:preferencesUrl]).to include('email_preferences')
      expect(payload[:footer]).to be_present
    end

    it 'renders the footer in the recipient locale' do
      user.update_columns(locale: 'zh-CN')

      zh = described_class.broadcast_payload(user, :notices, 's', 'b')[:footer]
      user.update_columns(locale: 'en')
      en = described_class.broadcast_payload(user, :notices, 's', 'b')[:footer]

      expect(zh).not_to eq(en)
    end

    it 'builds the release payload' do
      release = instance_double(
        Release, app_name: 'Demo iOS Beta', release_version: '1.2.0', build_version: '45',
                 changelog: [{ 'message' => 'Fixed login' }, ' '], release_url: 'https://zealot.test/releases/1'
      )

      payload = described_class.release_deployed_payload(release, user)

      expect(payload).to include(
        subject: a_string_including('Demo iOS Beta', '1.2.0 (45)'),
        changelog: ['Fixed login'], releaseUrl: 'https://zealot.test/releases/1', appName: 'Demo iOS Beta'
      )
    end
  end

  describe 'delivering through SMTP' do
    before { with_env({}) }

    it 'still queues the mailer' do
      expect do
        described_class.deliver_campaign(user, subject: 'News', body: 'Hi')
      end.to have_enqueued_mail(NotificationMailer, :campaign)
    end
  end
end
