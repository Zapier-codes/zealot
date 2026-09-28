# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-5b: a release's `update?`/`destroy?` also need the tenant rule, and
# `ReleasePolicy::Scope` reads through `Release.for_tenant`. Default host: unchanged. A tenant's
# host: only a member, and only that tenant's releases. `new?`/`create?`/`edit?` are untouched
# (the upload routes authorize them with a channel key and no user). Needs Postgres. Imitates
# app_write_tenant_spec.rb; NOT run in the sandbox that wrote it (no Rails boot or database there).
RSpec.describe 'Release write rules and tenants' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }
  let!(:default_app) { create(:app) }
  let!(:acme_app) { create(:app, tenant: acme) }
  let!(:globex_app) { create(:app, tenant: globex) }

  let(:admin) do
    User.create!(email: 'boss@example.com', username: 'boss', password: 'correct-horse-9',
                 password_confirmation: 'correct-horse-9', confirmed_at: Time.current, role: :admin)
  end

  def make_release(app)
    scheme = app.schemes.create!(name: 'Main')
    channel = scheme.channels.create!(name: 'Android', device_type: :android)
    Release.new(channel: channel, version: 1, changelog: [], release_version: '1.0.1',
                build_version: '1').tap { |release| release.save!(validate: false) }
  end

  let!(:default_release) { make_release(default_app) }
  let!(:acme_release) { make_release(acme_app) }
  let!(:globex_release) { make_release(globex_app) }

  # Task 27f-b: `update_status?` follows the same rule as `update?` and `destroy?`.
  let(:write_queries) { %i[update? destroy? update_status?] }

  def allowed?(user, record, query)
    Pundit.policy!(user, record).public_send(query)
  end

  before { allow(Setting).to receive(:guest_mode).and_return(false) }
  after { Current.reset }

  describe 'on the default host' do
    it 'changes nothing: an admin may still edit and delete every release, and the scope is all' do
      [default_release, acme_release, globex_release].each do |release|
        write_queries.each { |query| expect(allowed?(admin, release, query)).to be(true), query.to_s }
      end
      expect(Pundit.policy_scope!(admin, Release)).to match_array([default_release, acme_release, globex_release])
    end
  end

  describe 'on a tenant host' do
    before { Current.tenant = acme }

    it 'refuses a non-member update and destroy, and an empty scope' do
      write_queries.each { |query| expect(allowed?(admin, acme_release, query)).to be(false), query.to_s }
      expect(Pundit.policy_scope!(admin, Release)).to be_empty
      expect(Pundit.policy_scope!(nil, Release)).to be_empty
    end

    it 'lets a member admin change the tenant\'s own releases only' do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')

      write_queries.each { |query| expect(allowed?(admin, acme_release, query)).to be(true), query.to_s }
      [default_release, globex_release].each do |other|
        write_queries.each { |query| expect(allowed?(admin, other, query)).to be(false), query.to_s }
      end
      expect(Pundit.policy_scope!(admin, Release)).to contain_exactly(acme_release)
    end
  end
end
