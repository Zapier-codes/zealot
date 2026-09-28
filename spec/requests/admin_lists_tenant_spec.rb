# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7c-3: the admin lists (apps, collections, sponsored slots) read through the policy
# scope. Default host: everything, as before. A tenant's host: only a member sees anything, and only
# that tenant's rows; a cross-tenant id is a 404; a slot cannot be placed on another tenant's app.
# Written by imitating admin_collections_tenant_spec.rb; NOT run in the sandbox that wrote it (no
# Rails boot or database there), so it is the first thing to look at if CI is red for this slice.
RSpec.describe 'Admin lists and tenants', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }
  let(:admin) do
    User.create!(email: User.admin_signup_email, username: 'boss', password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: :admin)
  end
  let(:acme) { create(:tenant, tenant_id: 'acme', domains: ['store.acme.example.com']) }
  let(:globex) { create(:tenant, tenant_id: 'globex', domains: ['store.globex.example.com']) }

  let!(:default_app) { create(:app, name: 'Default App') }
  let!(:acme_app) { create(:app, name: 'Acme App', tenant: acme) }
  let!(:globex_app) { create(:app, name: 'Globex App', tenant: globex) }

  let!(:default_collection) { Collection.create!(slug: 'staff-picks', name: 'Staff picks') }
  let!(:acme_collection) { Collection.create!(slug: 'acme-picks', name: 'Acme picks', tenant: acme) }
  let!(:globex_collection) { Collection.create!(slug: 'globex-picks', name: 'Globex picks', tenant: globex) }

  let(:window) { { starts_at: 1.day.from_now, ends_at: 3.days.from_now } }
  let!(:default_slot) { SponsoredSlot.create!(app: default_app, **window) }
  let!(:acme_slot) { SponsoredSlot.create!(app: acme_app, **window) }
  let!(:globex_slot) { SponsoredSlot.create!(app: globex_app, **window) }

  before do
    Zealot::TenantRegistry.reset!
    sign_in admin
  end

  context 'on the default host' do
    it 'lists every app, collection and slot, tenants\' included (unchanged)' do
      get admin_apps_path
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')

      get admin_collections_path
      expect(response.body).to include('staff-picks', 'acme-picks', 'globex-picks')

      get admin_sponsored_slots_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')
    end

    it 'creates a collection with no tenant' do
      post admin_collections_path, params: { collection: { slug: 'new-picks', name: 'New picks' } }

      expect(Collection.find_by!(slug: 'new-picks').tenant_id).to be_nil
    end

    it 'places a slot on any app, and offers every app in the form' do
      get new_admin_sponsored_slot_path
      expect(response.body).to include('Default App', 'Acme App', 'Globex App')

      expect do
        post admin_sponsored_slots_path,
             params: { sponsored_slot: { app_id: acme_app.id, starts_at: 1.day.from_now, ends_at: 2.days.from_now } }
      end.to change(SponsoredSlot, :count).by(1)
    end
  end

  context 'on a tenant host, as an admin who is not a member' do
    before { host! 'store.acme.example.com' }

    it 'refuses every list (403) and cannot create' do
      get admin_apps_path
      expect(response).to have_http_status(:forbidden)

      get admin_collections_path
      expect(response).to have_http_status(:forbidden)

      get admin_sponsored_slots_path
      expect(response).to have_http_status(:forbidden)

      expect { post admin_collections_path, params: { collection: { slug: 'x-picks', name: 'X' } } }
        .not_to change(Collection, :count)
    end
  end

  context 'on a tenant host, as a member' do
    before do
      TenantMembership.create!(user: admin, tenant: acme, role: 'owner')
      host! 'store.acme.example.com'
    end

    it 'lists only the tenant\'s own apps' do
      get admin_apps_path

      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
      expect(response.body).not_to include('Globex App')
    end

    it 'lists only the tenant\'s own collections' do
      get admin_collections_path

      expect(response.body).to include('acme-picks')
      expect(response.body).not_to include('staff-picks')
      expect(response.body).not_to include('globex-picks')
    end

    it 'lists only the slots of the tenant\'s apps' do
      get admin_sponsored_slots_path

      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
      expect(response.body).not_to include('Globex App')
    end

    it 'answers 404 for another tenant\'s (or the default catalog\'s) collection, slot and app' do
      get edit_admin_collection_path(globex_collection)
      expect(response).to have_http_status(:not_found)

      get edit_admin_collection_path(default_collection)
      expect(response).to have_http_status(:not_found)

      get edit_admin_sponsored_slot_path(globex_slot)
      expect(response).to have_http_status(:not_found)

      put toggle_featured_admin_app_path(globex_app)
      expect(response).to have_http_status(:not_found)
      expect(globex_app.reload.featured).to be(false)
    end

    it 'still edits its own collection and toggles its own app' do
      get edit_admin_collection_path(acme_collection)
      expect(response).to have_http_status(:ok)

      put toggle_featured_admin_app_path(acme_app)
      expect(acme_app.reload.featured).to be(true)
    end

    it 'makes a new collection belong to the tenant, whatever the params say' do
      post admin_collections_path,
           params: { collection: { slug: 'fresh-picks', name: 'Fresh', tenant_id: globex.id } }

      expect(Collection.find_by!(slug: 'fresh-picks').tenant).to eq(acme)
    end

    it 'offers only the tenant\'s apps when placing a slot' do
      get new_admin_sponsored_slot_path

      expect(response.body).to include('Acme App')
      expect(response.body).not_to include('Default App')
      expect(response.body).not_to include('Globex App')
    end

    it 'places a slot on its own app but not on another tenant\'s or a default app' do
      attrs = { starts_at: 1.day.from_now, ends_at: 2.days.from_now }

      expect { post admin_sponsored_slots_path, params: { sponsored_slot: { app_id: acme_app.id, **attrs } } }
        .to change(SponsoredSlot, :count).by(1)

      [globex_app, default_app].each do |app|
        expect { post admin_sponsored_slots_path, params: { sponsored_slot: { app_id: app.id, **attrs } } }
          .not_to change(SponsoredSlot, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'cannot move its slot onto another tenant\'s app' do
      put admin_sponsored_slot_path(acme_slot), params: { sponsored_slot: { app_id: globex_app.id } }

      expect(response).to have_http_status(:not_found)
      expect(acme_slot.reload.app_id).to eq(acme_app.id)
    end
  end

  context 'on a tenant host, as a member of a different tenant' do
    before do
      TenantMembership.create!(user: admin, tenant: globex)
      host! 'store.acme.example.com'
    end

    it 'is refused like a non-member' do
      get admin_apps_path

      expect(response).to have_http_status(:forbidden)
    end
  end
end
