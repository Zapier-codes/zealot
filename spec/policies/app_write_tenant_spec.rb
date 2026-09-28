# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-6: the per-app WRITE rules also need the tenant rule. Default host: every
# predicate is what it was. A tenant's host: only a member of that tenant, and for a saved app only
# that tenant's app. Needs Postgres. Imitates tenant_access_spec.rb; NOT run in the sandbox that
# wrote it (no Rails boot or database there).
RSpec.describe 'App write rules and tenants' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }
  let!(:default_app) { create(:app) }
  let!(:acme_app) { create(:app, tenant: acme) }
  let!(:globex_app) { create(:app, tenant: globex) }

  let(:admin) do
    User.create!(email: 'boss@example.com', username: 'boss', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :admin)
  end

  def write_queries
    %i[create? edit? update? destroy? archive? archived? unarchive?]
  end

  def allowed?(user, record, query)
    Pundit.policy!(user, record).public_send(query)
  end

  before { allow(Setting).to receive(:guest_mode).and_return(false) }
  after { Current.reset }

  describe 'on the default host' do
    it 'changes nothing: an admin may still write to every app, tenant-owned included' do
      [default_app, acme_app, globex_app].each do |app|
        write_queries.each { |query| expect(allowed?(admin, app, query)).to be(true), "#{query} on #{app.id}" }
      end
      expect(allowed?(admin, App.new, :create?)).to be true
    end
  end

  describe 'on a tenant host' do
    before { Current.tenant = acme }

    it 'refuses a non-member every write, an admin included' do
      write_queries.each do |query|
        expect(allowed?(admin, acme_app, query)).to be(false), query.to_s
      end
      expect(allowed?(admin, App.new, :create?)).to be false
      expect(allowed?(admin, acme_app, :mark_paid?)).to be false
    end

    it 'lets a member admin write to the tenant\'s own apps only' do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')

      write_queries.each { |query| expect(allowed?(admin, acme_app, query)).to be(true), query.to_s }
      expect(allowed?(admin, App.new, :create?)).to be true

      [default_app, globex_app].each do |other|
        write_queries.each { |query| expect(allowed?(admin, other, query)).to be(false), query.to_s }
      end
    end

    it 'does not admit a member of another tenant' do
      TenantMembership.create!(user: admin, tenant: globex, role: 'owner')

      expect(allowed?(admin, acme_app, :update?)).to be false
      expect(allowed?(admin, App.new, :create?)).to be false
    end
  end
end
