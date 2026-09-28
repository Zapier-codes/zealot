# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s6a: the admin collection page only offers, and only adds, apps of the collection's own
# tenant. Written by imitating admin_tenant_keys_spec.rb; NOT run in the sandbox that wrote it (no
# Rails boot there), so it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Admin collections and tenants', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme') }
  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }

  before { sign_in admin }

  context 'with a default-tenant collection' do
    let!(:collection) { Collection.create!(slug: 'staff-picks', name: 'Staff picks') }

    it 'adds a default app' do
      expect { post add_app_admin_collection_path(collection), params: { app_id: default_app.id } }
        .to change { collection.apps.count }.by(1)

      expect(response).to redirect_to(edit_admin_collection_path(collection))
    end

    it 'does not add a tenant\'s app, and does not raise' do
      expect { post add_app_admin_collection_path(collection), params: { app_id: acme_app.id } }
        .not_to(change { collection.apps.count })

      expect(response).to redirect_to(edit_admin_collection_path(collection))
    end

    it 'offers only default apps on the edit page' do
      get edit_admin_collection_path(collection)

      expect(response.body).to include('Default App')
      expect(response.body).not_to include('Acme App')
    end
  end

  context 'with a tenant\'s collection' do
    let!(:collection) { Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme) }

    it 'adds the tenant\'s app but not a default app' do
      expect { post add_app_admin_collection_path(collection), params: { app_id: acme_app.id } }
        .to change { collection.apps.count }.by(1)
      expect { post add_app_admin_collection_path(collection), params: { app_id: default_app.id } }
        .not_to(change { collection.apps.count })
    end

    it 'offers only that tenant\'s apps on the edit page' do
      get edit_admin_collection_path(collection)

      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
    end
  end
end
