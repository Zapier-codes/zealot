# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-2 (❓4b-a, ❓4b-b): the access rule. On the default host nothing changes for
# anyone; on a tenant's host only a member of that tenant gets in, and only to that tenant's apps.
# Needs Postgres (real rows and memberships). Written by imitating app_ownership_spec.rb; NOT run in
# the sandbox that wrote it (no Rails boot or database there).
RSpec.describe 'Tenant access rule' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }

  let!(:default_app) { create(:app) }
  let!(:acme_app) { create(:app, tenant: acme) }
  let!(:globex_app) { create(:app, tenant: globex) }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: role)
  end

  def join(user, tenant, role: 'member')
    TenantMembership.create!(user: user, tenant: tenant, role: role)
  end

  def allowed?(user, record, query)
    Pundit.policy!(user, record).public_send(query)
  end

  def visible(user, model = App)
    Pundit.policy_scope!(user, model).to_a
  end

  let(:admin) { make_user('boss', :admin) }
  let(:developer) { make_user('dev', :developer) }
  let(:plain) { make_user('plain', :member) }

  before { allow(Setting).to receive(:guest_mode).and_return(false) }
  after { Current.reset }

  describe 'on the default host (Current.tenant is nil)' do
    it 'changes nothing: an admin and a developer still reach every app, tenant-owned included' do
      [admin, developer].each do |user|
        expect(allowed?(user, App, :index?)).to be true
        [default_app, acme_app, globex_app].each { |app| expect(allowed?(user, app, :show?)).to be true }
      end
    end

    it 'still denies a plain member with no collaboration, and still allows a collaborator' do
      expect(allowed?(plain, default_app, :show?)).to be false

      Collaborator.create!(user: plain, app: acme_app, role: :member, owner: false)
      expect(allowed?(plain, acme_app, :show?)).to be true
    end

    it 'lists every row in a policy scope' do
      expect(visible(admin)).to contain_exactly(default_app, acme_app, globex_app)
      expect(visible(plain)).to contain_exactly(default_app, acme_app, globex_app)
    end
  end

  describe 'on a tenant host (Current.tenant is the tenant)' do
    before { Current.tenant = acme }

    it 'denies a non-member everything, an admin included' do
      [admin, developer, plain].each do |user|
        expect(allowed?(user, App, :index?)).to be false
        expect(allowed?(user, acme_app, :show?)).to be false
      end
      expect(allowed?(nil, acme_app, :show?)).to be false
    end

    it 'denies a collaborator who is not a member of the tenant' do
      Collaborator.create!(user: plain, app: acme_app, role: :member, owner: false)

      expect(allowed?(plain, acme_app, :show?)).to be false
    end

    it 'lets a member developer see this tenant\'s apps and nobody else\'s' do
      join(developer, acme)

      expect(allowed?(developer, App, :index?)).to be true
      expect(allowed?(developer, acme_app, :show?)).to be true
      expect(allowed?(developer, default_app, :show?)).to be false
      expect(allowed?(developer, globex_app, :show?)).to be false
    end

    it 'gives a member admin no platform-wide power here (control plane and tenant plane are separate)' do
      join(admin, acme, role: 'owner')

      expect(allowed?(admin, acme_app, :show?)).to be true
      expect(allowed?(admin, default_app, :show?)).to be false
      expect(allowed?(admin, globex_app, :show?)).to be false
    end

    it 'keeps the per-app rule underneath: a member with no collaboration on the app still sees nothing' do
      join(plain, acme)
      expect(allowed?(plain, acme_app, :show?)).to be false

      Collaborator.create!(user: plain, app: acme_app, role: :member, owner: false)
      expect(allowed?(plain, acme_app, :show?)).to be true
    end

    it 'does not admit a member of another tenant' do
      join(developer, globex)

      expect(allowed?(developer, App, :index?)).to be false
      expect(allowed?(developer, acme_app, :show?)).to be false
    end

    it 'denies a guest even in guest mode (deny by default)' do
      allow(Setting).to receive(:guest_mode).and_return(true)

      expect(allowed?(nil, acme_app, :show?)).to be false
    end
  end

  describe 'policy scope on a tenant host' do
    before { Current.tenant = acme }

    it 'is empty for a non-member' do
      expect(visible(admin)).to be_empty
    end

    it 'is only the tenant\'s own rows for a member' do
      join(developer, acme)

      expect(visible(developer)).to contain_exactly(acme_app)
    end

    it 'covers other tenant-owned models through for_tenant' do
      join(developer, acme)
      mine = Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme)
      Collection.create!(slug: 'globex-picks', name: 'Globex picks', tenant: globex)
      Collection.create!(slug: 'staff-picks', name: 'Staff picks')

      expect(visible(developer, Collection)).to contain_exactly(mine)
    end

    it 'is empty for a model that cannot say which tenant a row belongs to' do
      join(developer, acme)
      scheme = default_app.schemes.create!(name: 'Main')

      expect(scheme).to be_persisted
      expect(visible(developer, Scheme)).to be_empty
    end
  end

  describe 'User#tenant_member? and User#platform_admin?' do
    it 'reports membership per tenant, and never for nil or an unsaved user' do
      join(developer, acme)

      expect(developer.tenant_member?(acme)).to be true
      expect(developer.tenant_member?(globex)).to be false
      expect(developer.tenant_member?(nil)).to be false
      expect(User.new.tenant_member?(acme)).to be false
    end

    it 'is true only for an admin on the default host' do
      expect(admin.platform_admin?).to be true
      expect(admin.platform_admin?(nil)).to be true
      expect(admin.platform_admin?(acme)).to be false
      expect(developer.platform_admin?).to be false
    end

    it 'does not treat membership as a role: a member admin is still no platform admin on the tenant host' do
      join(admin, acme, role: 'owner')

      expect(admin.platform_admin?(acme)).to be false
    end
  end
end
