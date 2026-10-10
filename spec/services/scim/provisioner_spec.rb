# frozen_string_literal: true

require 'rails_helper'

# Z-P18 (SCIM half; Play Console parity): what a SCIM create/update/delete does to Zealot -- the data rule
# behind Scim::UsersController. Written by reading the service, like the other slices' specs.
RSpec.describe Scim::Provisioner do
  let(:password) { 'correct-horse-9' }
  let(:tenant) { create(:tenant, tenant_id: 'acme') }
  let(:provisioner) { described_class.new(tenant: tenant) }

  def user_for(email)
    User.find_by(email: email)
  end

  describe '#create' do
    it 'makes an SSO account (random password, confirmed) and a tenant membership' do
      result = provisioner.create(email: 'ann@acme.example.com', username: 'Ann')

      expect(result).to be_ok
      expect(result.created).to be(true)
      expect(result.user).to be_persisted
      expect(result.user.confirmed_at).to be_present
      expect(result.membership.tenant).to eq(tenant)
      expect(result.membership.role).to eq('member')
    end

    it 'adopts an existing account by email instead of failing' do
      existing = User.create!(email: 'ann@acme.example.com', username: 'ann', password: password,
                              password_confirmation: password, confirmed_at: Time.current)

      result = provisioner.create(email: 'ANN@acme.example.com', username: 'Ann')

      expect(result).to be_ok
      expect(result.created).to be(false)
      expect(result.user).to eq(existing)
    end

    it 'defaults a missing username from the email, as an IdP that sends only userName still provisions' do
      result = provisioner.create(email: 'pat@acme.example.com')

      expect(result).to be_ok
      expect(result.user.username).to eq('pat')
    end

    it 'never makes the account an admin' do
      result = provisioner.create(email: 'ann@acme.example.com', username: 'Ann')

      expect(result.user.role).not_to eq('admin')
    end

    it 'reports an error and creates nothing when the email is blank' do
      result = provisioner.create(username: 'Ann')

      expect(result).not_to be_ok
      expect(result.errors).to include(/userName/i)
      expect(User.where(username: 'Ann')).to be_empty
    end

    it 'creates the account but no membership when it provisions active=false' do
      result = provisioner.create(email: 'ann@acme.example.com', username: 'Ann', active: false)

      expect(result).to be_ok
      expect(result.user).to be_persisted
      expect(TenantMembership.for_tenant(tenant)).to be_empty
    end
  end

  describe '#update' do
    let(:user) { create(:user, email: 'ann@acme.example.com', username: 'ann') }

    it 'changes only the attributes present, never blanking the rest' do
      result = provisioner.update(user, active: true)

      expect(result).to be_ok
      expect(user.reload.username).to eq('ann')
      expect(TenantMembership.find_by(user: user, tenant: tenant)).to be_present
    end

    it 'flips active=false by removing the membership and locking the account' do
      create(:tenant_membership, tenant: tenant, user: user)

      result = provisioner.update(user, active: false)

      expect(result).to be_ok
      expect(TenantMembership.for_tenant(tenant).where(user: user)).to be_empty
      expect(user.reload.access_locked?).to be(true)
    end

    it 're-provisions an inactive account by restoring the membership and unlocking' do
      user.lock_access!(send_instructions: false)

      result = provisioner.update(user, active: true)

      expect(result).to be_ok
      expect(TenantMembership.find_by(user: user, tenant: tenant)).to be_present
      expect(user.reload.access_locked?).to be(false)
    end
  end

  describe '#deactivate' do
    it 'drops the membership and locks the account, but keeps the row' do
      user = create(:user, email: 'ann@acme.example.com', username: 'ann')
      create(:tenant_membership, tenant: tenant, user: user)

      expect { provisioner.deactivate(user) }.not_to change(User, :count)
      expect(TenantMembership.for_tenant(tenant).where(user: user)).to be_empty
      expect(user.reload.access_locked?).to be(true)
    end

    it 'is idempotent' do
      user = create(:user, email: 'ann@acme.example.com', username: 'ann')

      provisioner.deactivate(user)
      expect { provisioner.deactivate(user) }.not_to raise_error
    end
  end

  context 'with a platform-scoped token (no tenant)' do
    let(:provisioner) { described_class.new(tenant: nil) }

    it 'creates an account and no membership' do
      result = provisioner.create(email: 'ann@acme.example.com', username: 'Ann')

      expect(result).to be_ok
      expect(result.membership).to be_nil
      expect(TenantMembership.count).to be_zero
    end
  end
end
