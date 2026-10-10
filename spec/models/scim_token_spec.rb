# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SCIM half; Play Console parity): the SCIM provisioning token's own rules (issue, authenticate,
# scope, revoke, expiry, the live cap). Written by reading the model, like the other slices' specs.
RSpec.describe ScimToken, type: :model do
  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:tenant) { create(:tenant, tenant_id: 'acme') }

  describe '.issue!' do
    it 'returns the row and a zsc_ secret that authenticates' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin)

      expect(issued.secret).to match(described_class::SECRET_FORMAT)
      expect(described_class.authenticate(issued.secret)).to eq(issued.token)
    end

    it 'stores only the digest and the last four, never the secret' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin)
      token = issued.token.reload

      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(issued.secret))
      expect(token.last_four).to eq(issued.secret[-4..])
      expect(token.attributes.values.map(&:to_s)).not_to include(issued.secret)
    end

    it 'is tenant-scoped with the provision scope by default' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin)

      expect(issued.token.tenant).to eq(tenant)
      expect(issued.token.scope?('provision')).to be(true)
    end
  end

  describe '.authenticate' do
    it 'rejects a malformed or unknown secret' do
      expect(described_class.authenticate('nope')).to be_nil
      expect(described_class.authenticate("#{described_class::PREFIX}#{'a' * 43}")).to be_nil
    end

    it 'rejects a revoked token' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin)
      issued.token.revoke!

      expect(described_class.authenticate(issued.secret)).to be_nil
    end

    it 'rejects an expired token' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin, expires_at: 1.hour.from_now)
      issued.token.update_column(:expires_at, 1.hour.ago)

      expect(described_class.authenticate(issued.secret)).to be_nil
    end
  end

  describe 'the live cap' do
    it 'refuses a sixth live token for the same tenant' do
      5.times { |i| described_class.issue!(tenant: tenant, name: "okta-#{i}", created_by: admin) }

      expect do
        described_class.issue!(tenant: tenant, name: 'one-too-many', created_by: admin)
      end.to raise_error(ActiveRecord::RecordInvalid, /at most 5/)
    end

    it 'lets a revoked token be replaced without counting against the cap' do
      5.times { |i| described_class.issue!(tenant: tenant, name: "okta-#{i}", created_by: admin) }
      described_class.for_tenant(tenant).first.revoke!

      expect do
        described_class.issue!(tenant: tenant, name: 'replacement', created_by: admin)
      end.not_to raise_error
    end
  end

  describe '#record_use!' do
    it 'stamps last-used once and then throttles' do
      issued = described_class.issue!(tenant: tenant, name: 'okta', created_by: admin)
      token = issued.token

      expect(token.record_use!).to be(true)
      expect(token.reload.last_used_at).to be_present
      expect(token.record_use!).to be(false)
    end
  end
end
