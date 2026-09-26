# frozen_string_literal: true

require 'rails_helper'

RSpec.describe App do
  # Task 27c: go_live!, suspend! and a listing edit on a live app must each
  # enqueue a catalog index republish; nothing else on App should.
  describe 'catalog index publish on save' do
    it 'enqueues a publish on go_live!' do
      app = create(:app, listing_status: :awaiting_payment)

      expect { app.go_live! }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'enqueues a publish on suspend!' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.suspend! }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'does not suspend an app that is not live' do
      app = create(:app, listing_status: :draft)

      expect(app.suspend!).to eq(false)
      expect(app.reload).to be_listing_draft
    end

    it 'enqueues a publish when a live app is renamed' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.update!(name: 'New Name') }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'enqueues a publish when a live app changes publisher_alias' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.update!(publisher_alias: 'Ada Labs') }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'enqueues a publish when a live app changes play_package_name' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.update!(play_package_name: 'com.example.app') }.to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'does not enqueue a publish for an unrelated field change' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.update!(archived: true) }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end

    it 'does not enqueue a publish on create' do
      expect { create(:app) }.not_to have_enqueued_job(CatalogIndexPublishJob)
    end
  end
end
