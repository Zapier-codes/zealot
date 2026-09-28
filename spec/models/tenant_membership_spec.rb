# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-0 (❓4b-a): `tenant_memberships`, the record of who belongs to which tenant.
# No caller reads it yet. Needs Postgres (real foreign keys, `restrict_with_error`, the unique
# index). Written by imitating collection_tenant_spec.rb; NOT run in the sandbox that wrote it
# (no Rails boot or database there).
RSpec.describe TenantMembership do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }

  def make_user(name)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current)
  end

  let(:alice) { make_user('alice') }
  let(:bob) { make_user('bob') }

  describe 'a new membership' do
    it 'defaults to the member role' do
      membership = described_class.create!(user: alice, tenant: acme)

      expect(membership.role).to eq('member')
      expect(membership).to be_member
      expect(membership).not_to be_owner
    end

    it 'accepts owner and member, and refuses any other role' do
      expect(build(:tenant_membership, tenant: acme, user: alice, role: 'owner')).to be_valid
      expect(build(:tenant_membership, tenant: acme, user: alice, role: 'member')).to be_valid
      expect(build(:tenant_membership, tenant: acme, user: alice, role: 'admin')).not_to be_valid
    end

    it 'needs both a user and a tenant' do
      expect(build(:tenant_membership, tenant: acme, user: nil)).not_to be_valid
      expect(build(:tenant_membership, tenant: nil, user: alice)).not_to be_valid
    end
  end

  describe 'one membership per (user, tenant)' do
    it 'lets one user belong to two tenants' do
      described_class.create!(user: alice, tenant: acme)
      described_class.create!(user: alice, tenant: globex, role: 'owner')

      expect(alice.tenant_memberships.count).to eq(2)
      expect(alice.tenants).to contain_exactly(acme, globex)
    end

    it 'lets one tenant have several members' do
      described_class.create!(user: alice, tenant: acme, role: 'owner')
      described_class.create!(user: bob, tenant: acme)

      expect(acme.members).to contain_exactly(alice, bob)
    end

    it 'refuses a duplicate pair in the model' do
      described_class.create!(user: alice, tenant: acme)

      dup = build(:tenant_membership, user: alice, tenant: acme, role: 'owner')
      expect(dup).not_to be_valid
      expect(dup.errors[:user_id]).not_to be_empty
    end

    it 'refuses a duplicate pair at the unique index too' do
      described_class.create!(user: alice, tenant: acme)

      dup = build(:tenant_membership, user: alice, tenant: acme)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe 'the database role check' do
    it 'refuses an unknown role even when validations are skipped' do
      membership = described_class.create!(user: alice, tenant: acme)

      expect do
        described_class.connection.execute("UPDATE tenant_memberships SET role = 'admin' WHERE id = #{membership.id}")
      end.to raise_error(ActiveRecord::StatementInvalid)
    end
  end

  describe 'scopes' do
    it 'narrows to one tenant or one user' do
      a = described_class.create!(user: alice, tenant: acme)
      b = described_class.create!(user: bob, tenant: acme)
      c = described_class.create!(user: alice, tenant: globex)

      expect(described_class.for_tenant(acme)).to contain_exactly(a, b)
      expect(described_class.for_user(alice)).to contain_exactly(a, c)
    end
  end

  describe 'Tenant#destroy' do
    it 'is refused while the tenant has members, and the membership is left alone' do
      membership = described_class.create!(user: alice, tenant: acme)

      expect(acme.destroy).to be false
      expect(acme.errors[:base]).not_to be_empty
      expect(membership.reload.tenant).to eq(acme)
    end

    it 'is allowed once the members are gone' do
      described_class.create!(user: alice, tenant: acme).destroy!

      expect(acme.destroy).to be_truthy
    end
  end

  describe 'User#destroy' do
    it "removes the user's own memberships and leaves the tenant and its other members" do
      described_class.create!(user: alice, tenant: acme)
      described_class.create!(user: alice, tenant: globex)
      described_class.create!(user: bob, tenant: acme)

      alice.destroy!

      expect(described_class.where(user_id: alice.id)).to be_empty
      expect(acme.reload.members).to contain_exactly(bob)
      expect(Tenant.exists?(globex.id)).to be(true)
    end
  end

  describe '#last_owner?' do
    let(:tenant) { create(:tenant) }

    it 'is true for the only owner, false once there is a second owner, false for a member' do
      only = create(:tenant_membership, :owner, tenant: tenant)
      member = create(:tenant_membership, tenant: tenant)

      expect(only.last_owner?).to be true
      expect(member.last_owner?).to be false

      create(:tenant_membership, :owner, tenant: tenant)
      expect(only.last_owner?).to be false
    end

    it 'does not count owners of another tenant' do
      mine = create(:tenant_membership, :owner, tenant: tenant)
      create(:tenant_membership, :owner)

      expect(mine.last_owner?).to be true
    end
  end
end
