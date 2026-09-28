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

    # Task 37b-iii-s5: the publish goes to the tenant that owns the app, and only that tenant.
    context 'when the app belongs to a tenant' do
      let(:tenant) { create(:tenant, tenant_id: 'acme') }

      it "republishes only that tenant when its app's listing changes" do
        app = create(:app, listing_status: :live, listed_at: Time.current, tenant: tenant)

        expect { app.update!(name: 'Renamed') }
          .to have_enqueued_job(CatalogIndexPublishJob).with('acme').exactly(:once)
        expect { app.update!(name: 'Renamed again') }
          .to have_enqueued_job(CatalogIndexPublishJob).exactly(:once) # that one job, no second publish
      end

      it 'republishes only that tenant on suspend!' do
        app = create(:app, listing_status: :live, listed_at: Time.current, tenant: tenant)

        expect { app.suspend! }.to have_enqueued_job(CatalogIndexPublishJob).with('acme').exactly(:once)
      end

      it 'never republishes the default tenant for a tenant-owned change' do
        app = create(:app, listing_status: :live, listed_at: Time.current, tenant: tenant)

        expect { app.update!(name: 'Renamed') }.not_to have_enqueued_job(CatalogIndexPublishJob).with(no_args)
      end
    end

    it 'republishes only the default tenant (no argument) for a default-tenant app' do
      app = create(:app, listing_status: :live, listed_at: Time.current)

      expect { app.update!(name: 'Renamed') }
        .to have_enqueued_job(CatalogIndexPublishJob).with(no_args).exactly(:once)
    end

    context 'when an app moves between tenants' do
      let(:acme) { create(:tenant, tenant_id: 'acme') }
      let(:globex) { create(:tenant, tenant_id: 'globex') }

      it 'republishes both the tenant it left and the tenant it joined' do
        app = create(:app, listing_status: :live, listed_at: Time.current, tenant: acme)

        expect { app.update!(tenant: globex) }
          .to have_enqueued_job(CatalogIndexPublishJob).with('globex').exactly(:once)
          .and have_enqueued_job(CatalogIndexPublishJob).with('acme').exactly(:once)
      end

      it 'republishes the default tenant too when the app leaves the default catalog' do
        app = create(:app, listing_status: :live, listed_at: Time.current)

        expect { app.update!(tenant: acme) }
          .to have_enqueued_job(CatalogIndexPublishJob).with('acme')
          .and have_enqueued_job(CatalogIndexPublishJob).with(no_args)
      end

      it 'republishes the tenant it left when the app returns to the default catalog' do
        app = create(:app, listing_status: :live, listed_at: Time.current, tenant: acme)

        expect { app.update!(tenant: nil) }
          .to have_enqueued_job(CatalogIndexPublishJob).with('acme')
          .and have_enqueued_job(CatalogIndexPublishJob).with(no_args)
      end
    end
  end

  # Task 27d-d1: one YouTube video ID per app, never a URL (docs/store_listing_graphics.md,
  # "Video"). ListingGraphicRules.youtube_id? is the format check this validation defers to; its
  # own examples (spec/services/listing_graphic_rules_spec.rb) cover the format in detail.
  describe 'promo_video_youtube_id' do
    it 'accepts a plain video id' do
      app = build(:app, promo_video_youtube_id: 'dQw4w9WgXcQ')

      expect(app).to be_valid
    end

    it 'accepts a blank value' do
      expect(build(:app, promo_video_youtube_id: nil)).to be_valid
      expect(build(:app, promo_video_youtube_id: '  ')).to be_valid
    end

    it 'refuses a full URL' do
      app = build(:app, promo_video_youtube_id: 'https://youtube.com/watch?v=dQw4w9WgXcQ')

      expect(app).not_to be_valid
      expect(app.errors[:promo_video_youtube_id]).not_to be_empty
    end

    it 'strips surrounding whitespace before validating' do
      app = build(:app, promo_video_youtube_id: '  dQw4w9WgXcQ  ')
      app.valid?

      expect(app.promo_video_youtube_id).to eq('dQw4w9WgXcQ')
    end
  end
end
