# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s6a (`collections.tenant_id`, `Collection.for_tenant`, and the rule that a
# membership never crosses tenants). Needs Postgres: the column is a real foreign key and
# `Tenant#collections` is `restrict_with_error`. Written by imitating app_tenant_spec.rb; NOT run in
# the sandbox that wrote it (no Rails boot or database there).
RSpec.describe Collection, 'tenant ownership' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let(:globex) { create(:tenant, tenant_id: 'globex') }

  def collection(slug, **attrs) = described_class.create!(slug: slug, name: slug.tr('-', ' '), **attrs)

  describe 'collections.tenant_id' do
    it 'leaves a new collection in the default registry: no tenant' do
      expect(collection('staff-picks').tenant_id).to be_nil
    end

    it 'lets a collection be assigned to a tenant' do
      picks = collection('acme-picks', tenant: acme)

      expect(picks.reload.tenant).to eq(acme)
      expect(acme.collections).to contain_exactly(picks)
    end

    it 'refuses to point at a tenant row that does not exist (foreign key)' do
      picks = collection('staff-picks')

      expect { picks.update_columns(tenant_id: 0) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it 'keeps the slug globally unique, across tenants' do
      collection('picks', tenant: acme)

      expect { collection('picks', tenant: globex) }.to raise_error(ActiveRecord::RecordInvalid, /slug/i)
      expect { collection('picks') }.to raise_error(ActiveRecord::RecordInvalid, /slug/i)
    end
  end

  describe '.for_tenant' do
    let!(:default_picks) { collection('staff-picks') }
    let!(:acme_picks) { collection('acme-picks', tenant: acme) }
    let!(:globex_picks) { collection('globex-picks', tenant: globex) }

    it 'gives the default tenant only the collections with no tenant' do
      [ nil, 'default', 'DEFAULT' ].each do |default|
        expect(described_class.for_tenant(default)).to contain_exactly(default_picks), "for #{default.inspect}"
      end
    end

    it 'gives a tenant only its own collections' do
      expect(described_class.for_tenant(acme)).to contain_exactly(acme_picks)
      expect(described_class.for_tenant(globex)).to contain_exactly(globex_picks)
    end

    it 'accepts a tenant id string in any case, or a resolver Ref' do
      ref = Zealot::TenantResolver::Ref.new('acme', nil)

      expect(described_class.for_tenant('acme')).to contain_exactly(acme_picks)
      expect(described_class.for_tenant('ACME')).to contain_exactly(acme_picks)
      expect(described_class.for_tenant(ref)).to contain_exactly(acme_picks)
    end

    it 'gives an unknown tenant nothing, never the default registry' do
      expect(described_class.for_tenant('no-such-tenant')).to be_empty
    end

    it 'composes with other scopes' do
      expect(described_class.for_tenant(acme).ordered).to contain_exactly(acme_picks)
    end
  end

  describe 'Tenant#destroy' do
    it 'is refused while the tenant owns collections, and the collections are left alone' do
      picks = collection('acme-picks', tenant: acme)

      expect(acme.destroy).to be false
      expect(acme.errors[:base]).not_to be_empty
      expect(picks.reload.tenant).to eq(acme)
    end

    it 'is allowed once the collections are gone' do
      collection('acme-picks', tenant: acme).destroy!

      expect(acme.destroy).to be_truthy
    end
  end

  describe 'CollectionApp membership' do
    let(:default_app) { create(:app) }
    let(:acme_app) { create(:app, tenant: acme) }
    let!(:default_picks) { collection('staff-picks') }
    let!(:acme_picks) { collection('acme-picks', tenant: acme) }

    it 'allows an app in a collection of the same tenant, default included' do
      expect(CollectionApp.new(app: default_app, collection: default_picks)).to be_valid
      expect(CollectionApp.new(app: acme_app, collection: acme_picks)).to be_valid
    end

    it 'refuses a tenant\'s app in a default collection' do
      membership = CollectionApp.new(app: acme_app, collection: default_picks)

      I18n.with_locale(:en) do # the app's default locale is zh-CN; the text below is the English one
        expect(membership).not_to be_valid
        expect(membership.errors[:app]).to include('belongs to a different tenant than this collection')
      end
    end

    it 'refuses a default app in a tenant\'s collection' do
      expect(CollectionApp.new(app: default_app, collection: acme_picks)).not_to be_valid
    end

    it 'refuses another tenant\'s app in a tenant\'s collection' do
      globex_app = create(:app, tenant: globex)

      expect(CollectionApp.new(app: globex_app, collection: acme_picks)).not_to be_valid
    end

    it 'leaves existing default memberships valid (no tenant on either side)' do
      membership = CollectionApp.create!(app: default_app, collection: default_picks)

      expect(membership.reload).to be_valid
    end
  end
end
