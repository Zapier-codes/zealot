# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NotificationMailer, type: :mailer do
  let(:user) do
    User.create!(email: 'dev@example.com', username: 'dev', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current,
                 role: :developer, locale: 'en')
  end

  describe '#notice' do
    it 'sends the given subject and body with a preferences link' do
      mail = described_class.notice(user, subject: 'Maintenance tonight', body: 'Back at 02:00.')

      expect(mail.to).to eq(['dev@example.com'])
      expect(mail.subject).to eq('Maintenance tonight')
      expect(mail.body.encoded).to include('Back at 02:00.')
      expect(mail.body.encoded).to include('email_preferences')
    end

    it 'escapes HTML in the body' do
      mail = described_class.notice(user, subject: 's', body: '<script>alert(1)</script>')

      expect(mail.html_part.body.decoded).not_to include('<script>alert(1)</script>')
    end
  end

  describe '#campaign' do
    it 'adds a List-Unsubscribe header' do
      mail = described_class.campaign(user, subject: 'News', body: 'Hello')

      expect(mail['List-Unsubscribe'].to_s).to include('email_preferences')
    end
  end

  describe '#release_deployed' do
    it 'mentions the app and version and links to the release' do
      release = instance_double(
        Release, app_name: 'Demo iOS Beta', release_version: '1.2.0', build_version: '45',
                 changelog: [{ 'message' => 'Fixed login' }], release_url: 'https://zealot.test/releases/1',
                 app: instance_double(App, name: 'Demo')
      )

      mail = described_class.release_deployed(release, user)

      expect(mail.subject).to include('Demo iOS Beta').and include('1.2.0 (45)')
      expect(mail.body.encoded).to include('Fixed login').and include('https://zealot.test/releases/1')
    end
  end
end
