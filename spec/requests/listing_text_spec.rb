# frozen_string_literal: true

require 'rails_helper'

# Task 27e-c: GET and PATCH /apps/:app_id/listing_text. Needs Postgres. NOT run in the sandbox that wrote
# it (no Rails boot or database there), so look here first if CI is red. What the page does with a draft is
# the staging layer's job (spec/models/listing_edit_spec.rb, spec/services/listing_edit_service_spec.rb);
# this file checks the page: who may use it, that it stages and never publishes, and how it refuses.
RSpec.describe 'Listing text editor', type: :request do
  include Devise::Test::IntegrationHelpers

  let(:password) { 'correct-horse-9' }

  def make_user(name, role)
    User.create!(email: "#{name}@example.com", username: name, password: password,
                 password_confirmation: password, confirmed_at: Time.current, role: role)
  end

  def save_text(fields)
    patch app_listing_text_path(app), params: { listing_text: fields }
  end

  def draft
    app.listing_edits.status_draft.first
  end

  let(:admin) { make_user('boss', :admin) }
  let(:owner) { make_user('owner', :developer) }
  let(:teammate) { make_user('teammate', :member) }
  let(:stranger) { make_user('stranger', :developer) }
  let!(:app) { create(:app, name: 'Text app', short_description: 'Live short', description: 'Live long') }

  before do
    Zealot::TenantRegistry.reset!
    allow(Setting).to receive(:guest_mode).and_return(false)
    app.create_owner(owner)
    Collaborator.create!(user: teammate, app: app, role: :member, owner: false)
  end

  context 'as the app owner' do
    before { sign_in owner }

    describe 'GET' do
      it 'shows the form filled with the live text when there is no draft' do
        get app_listing_text_path(app)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Text app', 'Live short', 'Live long')
        expect(response.body).not_to include(I18n.t('apps.listing_texts.show.draft_notice', fields: 'x').split('x').first)
        expect(app.listing_edits.count).to eq(0) # looking creates no draft
      end

      it 'shows what the draft would publish, and what is live now for a changed field' do
        ListingEdit.create!(app: app, editor: owner, staged_attributes: { 'short_description' => 'Draft short' })

        get app_listing_text_path(app)

        expect(response.body).to include('Draft short', 'Live long')
        expect(response.body).to include(I18n.t('apps.listing_texts.show.live_now', text: 'Live short'))
      end
    end

    describe 'PATCH' do
      it 'stages a change into the draft and leaves the live listing as it is' do
        save_text(name: 'New name', short_description: 'New short', description: 'New long')

        expect(response).to redirect_to(app_listing_text_path(app))
        expect(flash[:notice]).to eq(I18n.t('apps.listing_texts.update.saved'))
        expect(draft.staged_attributes).to eq('name' => 'New name', 'short_description' => 'New short',
                                              'description' => 'New long')
        expect(draft.editor).to eq(owner)
        app.reload
        expect([ app.name, app.short_description, app.description ]).to eq([ 'Text app', 'Live short', 'Live long' ])
      end

      it 'does not republish the catalog index, even for a live app' do
        allow_any_instance_of(App).to receive(:listing_live?).and_return(true)

        expect { save_text(description: 'New long') }.not_to have_enqueued_job(CatalogIndexPublishJob)
      end

      it 'stages only the fields that differ from the live listing' do
        save_text(name: 'Text app', short_description: 'Live short', description: 'Changed long')

        expect(draft.staged_attributes).to eq('description' => 'Changed long')
      end

      it 'stages the text the way the app will store it' do
        save_text(short_description: "Two\r\nlines  ", description: "One.\r\n\r\n\r\n\r\nTwo.  ")

        expect(draft.staged_attributes).to eq('short_description' => 'Two lines', 'description' => "One.\n\nTwo.")
      end

      it 'keeps earlier staged fields when another is saved' do
        save_text(name: 'New name')
        save_text(description: 'New long')

        expect(draft.staged_attributes).to eq('name' => 'New name', 'description' => 'New long')
        expect(app.listing_edits.count).to eq(1)
      end

      it 'takes a field out of the draft when it is put back to the live value' do
        save_text(name: 'New name', description: 'New long')

        save_text(name: 'Text app', description: 'New long')

        expect(draft.staged_attributes).to eq('description' => 'New long')
        expect(flash[:notice]).to eq(I18n.t('apps.listing_texts.update.saved'))
      end

      it 'clears a description that is sent blank' do
        save_text(description: '   ')

        expect(draft.staged_attributes).to eq('description' => nil)
      end

      it 'says nothing was changed when nothing differs, and creates no draft' do
        save_text(name: 'Text app', short_description: 'Live short', description: 'Live long')

        expect(response).to redirect_to(app_listing_text_path(app))
        expect(flash[:notice]).to eq(I18n.t('apps.listing_texts.update.unchanged'))
        expect(app.listing_edits.count).to eq(0)
      end

      it 'leaves a field that is not sent alone' do
        save_text(name: 'New name')
        save_text(description: 'New long')

        expect(draft.staged_attributes.keys).to contain_exactly('name', 'description')
      end

      it 'ignores fields outside the three text fields' do
        save_text(name: 'New name', category: 'games', play_package_name: 'com.evil.app')

        expect(draft.staged_attributes).to eq('name' => 'New name')
      end

      it 'refuses an over-long description, says why, and keeps the draft as it was' do
        save_text(name: 'New name')

        save_text(description: 'x' * (ListingText::DESCRIPTION_MAX_LENGTH + 1))

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include('description')
        expect(draft.reload.staged_attributes).to eq('name' => 'New name')
        expect(app.reload.description).to eq('Live long')
      end

      it 'refuses an over-long short description and shows what was typed' do
        long = 'y' * (ListingText::SHORT_DESCRIPTION_MAX_LENGTH + 1)

        save_text(short_description: long)

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include(long)
        expect(app.reload.short_description).to eq('Live short')
        expect(draft&.staged_attributes.to_h).to eq({})
      end

      it 'refuses a blank name' do
        save_text(name: '   ')

        expect(response).to have_http_status(:unprocessable_entity)
        expect(app.reload.name).to eq('Text app')
        expect(draft&.staged_attributes.to_h).to eq({})
      end

      it 'treats a malformed request as a 400 and stages nothing' do
        patch app_listing_text_path(app)
        expect(response).to have_http_status(:bad_request)

        patch app_listing_text_path(app), params: { listing_text: 'x' }
        expect(response).to have_http_status(:bad_request)

        save_text(name: [ 'x' ])
        expect(response).to have_http_status(:bad_request)

        save_text(category: 'games')
        expect(response).to have_http_status(:bad_request)

        expect(app.listing_edits.count).to eq(0)
      end

      it 'refuses an archived app' do
        app.update_columns(archived: true)

        save_text(name: 'New name')

        expect(app.listing_edits.count).to eq(0)
      end
    end
  end

  context 'as an admin' do
    before { sign_in admin }

    it 'may open the page and stage a change on any app' do
      get app_listing_text_path(app)
      expect(response).to have_http_status(:ok)

      save_text(name: 'Admin name')
      expect(draft.staged_attributes).to eq('name' => 'Admin name')
    end
  end

  context 'as a plain member collaborator, an unrelated developer or a signed-out visitor' do
    it 'is refused on the page and on the save, and changes nothing' do
      [ teammate, stranger ].each do |user|
        sign_in user

        get app_listing_text_path(app)
        expect(response).to have_http_status(:forbidden)

        save_text(name: 'Nope')
        expect(response).to have_http_status(:forbidden)

        sign_out user
      end

      get app_listing_text_path(app)
      expect(response).not_to have_http_status(:ok)
      save_text(name: 'Nope')
      expect(response).not_to have_http_status(:ok)

      expect(app.listing_edits.count).to eq(0)
      expect(app.reload.name).to eq('Text app')
    end

    it 'does not show the entry button on the app page' do
      sign_in teammate

      get app_path(app)

      expect(response.body).not_to include(app_listing_text_path(app))
    end
  end

  context 'the entry button on the app page' do
    it 'is shown to the owner' do
      sign_in owner

      get app_path(app)

      expect(response.body).to include(app_listing_text_path(app))
    end
  end

  context 'on a tenant\'s host' do
    let(:acme) { create(:tenant, tenant_id: 'acme', domains: [ 'store.acme.example.com' ]) }
    let!(:acme_app) { create(:app, name: 'Acme app', tenant: acme) }

    before do
      acme_app.create_owner(owner)
      sign_in owner
      host! 'store.acme.example.com'
    end

    it 'refuses someone who is not a member of the tenant, even for the app they own' do
      patch app_listing_text_path(acme_app), params: { listing_text: { name: 'Nope' } }

      expect(response).to have_http_status(:forbidden)
      expect(acme_app.listing_edits.count).to eq(0)
    end

    it 'lets a member stage a change on that tenant\'s app' do
      TenantMembership.create!(user: owner, tenant: acme, role: 'owner')

      patch app_listing_text_path(acme_app), params: { listing_text: { name: 'Acme new' } }

      expect(acme_app.listing_edits.status_draft.first.staged_attributes).to eq('name' => 'Acme new')
    end

    it 'refuses a member for an app that is not the tenant\'s' do
      TenantMembership.create!(user: owner, tenant: acme, role: 'owner')

      save_text(name: 'Nope')

      expect(response).to have_http_status(:forbidden)
      expect(app.listing_edits.count).to eq(0)
    end
  end
end
