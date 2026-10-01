# frozen_string_literal: true

require 'rails_helper'

# Task 34a-1 (Storeapp leaf `f.xiv`): a per-app API token exists as data. Written by reading the
# model, NOT run (no Ruby, Rails or database in the sandbox that wrote it), so it is the first thing
# to look at if CI is red for this slice.
RSpec.describe AppApiToken, type: :model do
  let(:password) { 'correct-horse-9' }
  let(:owner) do
    User.create!(email: 'owner@example.com', username: 'owner', password: password,
                 password_confirmation: password, confirmed_at: Time.current)
  end
  let!(:app) { create(:app, name: 'Token App') }
  let!(:other_app) { create(:app, name: 'Other App') }

  def issue(on: app, name: 'ci', **opts)
    described_class.issue!(app: on, name: name, created_by: owner, **opts)
  end

  describe '.issue!' do
    it 'returns the row and a zpa_ secret that authenticates' do
      issued = issue

      expect(issued.secret).to match(described_class::SECRET_FORMAT)
      expect(described_class.authenticate(issued.secret)).to eq(issued.token)
    end

    it 'stores only the SHA-256 digest, never the secret' do
      issued = issue

      stored = issued.token.reload
      expect(stored.token_digest).to eq(Digest::SHA256.hexdigest(issued.secret))
      expect(stored.attributes.values.compact.map(&:to_s)).not_to include(issued.secret)
      expect(stored.last_four).to eq(issued.secret[-4..])
    end

    it 'gives every token a different secret' do
      expect(issue(name: 'one').secret).not_to eq(issue(name: 'two').secret)
    end

    it 'defaults to the publish scope' do
      expect(issue.token.scopes).to eq(['publish'])
    end

    it 'refuses a blank name, a past expiry and an unknown or empty scope' do
      expect { issue(name: ' ') }.to raise_error(ActiveRecord::RecordInvalid)
      expect { issue(expires_at: 1.hour.ago) }.to raise_error(ActiveRecord::RecordInvalid)
      expect { issue(scopes: ['admin']) }.to raise_error(ActiveRecord::RecordInvalid)
      expect { issue(scopes: []) }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it 'refuses the 11th live token for an app, and a revoked one frees a place' do
      tokens = Array.new(described_class::MAX_LIVE_PER_APP) { |i| issue(name: "t#{i}").token }

      expect { issue(name: 'eleventh') }.to raise_error(ActiveRecord::RecordInvalid, /at most 10/)

      tokens.first.revoke!
      expect { issue(name: 'eleventh') }.not_to raise_error
    end

    it 'counts the cap per app' do
      described_class::MAX_LIVE_PER_APP.times { |i| issue(name: "t#{i}") }

      expect { issue(on: other_app, name: 'first on the other app') }.not_to raise_error
    end
  end

  describe '.authenticate' do
    it 'answers nil for an unknown, malformed or non-string secret' do
      issue

      expect(described_class.authenticate(described_class.generate_secret)).to be_nil
      expect(described_class.authenticate('zpa_short')).to be_nil
      expect(described_class.authenticate('nope')).to be_nil
      expect(described_class.authenticate(nil)).to be_nil
      expect(described_class.authenticate(['zpa_x'])).to be_nil
    end

    it 'answers nil for a secret with the wrong prefix even if the body is right' do
      issued = issue
      wrong = issued.secret.sub('zpa_', 'zpb_')

      expect(described_class.authenticate(wrong)).to be_nil
    end

    it 'answers nil once revoked' do
      issued = issue
      issued.token.revoke!

      expect(described_class.authenticate(issued.secret)).to be_nil
    end

    it 'answers nil once expired, and still answers before it' do
      issued = issue(expires_at: 1.day.from_now)
      expect(described_class.authenticate(issued.secret)).to eq(issued.token)

      issued.token.update_columns(expires_at: 1.minute.ago)
      expect(described_class.authenticate(issued.secret)).to be_nil
    end

    it 'never matches one app\'s token to another app' do
      issued = issue(on: app)

      expect(described_class.authenticate(issued.secret).app_id).to eq(app.id)
      expect(described_class.authenticate(issued.secret).app_id).not_to eq(other_app.id)
    end
  end

  describe '#revoke!' do
    it 'sets revoked_at once and keeps the row' do
      token = issue.token
      token.revoke!
      first = token.reload.revoked_at

      token.revoke!(1.hour.from_now)

      expect(token.reload.revoked_at).to eq(first)
      expect(described_class.exists?(token.id)).to be(true)
    end
  end

  describe '#record_use!' do
    it 'stamps last_used_at, then not again within the throttle' do
      token = issue.token
      now = Time.current

      expect(token.record_use!(now)).to be(true)
      expect(token.record_use!(now + 30.seconds)).to be(false)
      expect(token.record_use!(now + 2.minutes)).to be(true)
    end

    it 'does not stamp a revoked token' do
      token = issue.token
      token.revoke!

      expect(token.record_use!).to be(false)
      expect(token.reload.last_used_at).to be_nil
    end
  end

  describe 'lifecycle' do
    it 'is destroyed with its app' do
      issue
      expect { app.destroy! }.to change(described_class, :count).by(-1)
    end

    it 'survives its creator being deleted, with created_by cleared' do
      token = issue.token
      owner.destroy!

      expect(token.reload.created_by_id).to be_nil
    end
  end
end
