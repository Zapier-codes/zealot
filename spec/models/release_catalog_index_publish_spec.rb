# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s5: a new release of a live app republishes the catalog of the tenant that owns
# the app (the default tenant for an app with no tenant), and nothing for an app that is not live.
# Built the same way app_catalog_releases_track_spec.rb builds releases (no Release factory
# exists; `save!(validate: false)` skips the create-only `file` presence validation).
RSpec.describe Release, 'catalog index publish on create (Task 37b-iii-s5)' do
  def create_release_for(app)
    scheme = app.schemes.first || app.schemes.create!(name: 'Main')
    channel = scheme.channels.first ||
              scheme.channels.create!(name: 'Android', device_type: :android)
    release = Release.new(channel: channel, version: Release.count + 1, changelog: [],
                          release_version: '1.0.1', build_version: '1')
    release.save!(validate: false)
    release
  end

  it "republishes only the owning tenant for a live tenant app's new release" do
    tenant = create(:tenant, tenant_id: 'acme')
    app = App.create!(name: 'Tenant app', listing_status: :live, listed_at: Time.current, tenant: tenant)

    expect { create_release_for(app) }
      .to have_enqueued_job(CatalogIndexPublishJob).with('acme').exactly(:once)
    expect { create_release_for(app) }.not_to have_enqueued_job(CatalogIndexPublishJob).with(no_args)
  end

  it 'republishes the default tenant (no argument) for a live default-tenant app' do
    app = App.create!(name: 'Default app', listing_status: :live, listed_at: Time.current)

    expect { create_release_for(app) }
      .to have_enqueued_job(CatalogIndexPublishJob).with(no_args).exactly(:once)
  end

  it 'republishes nothing for an app that is not live' do
    tenant = create(:tenant, tenant_id: 'acme')
    app = App.create!(name: 'Draft app', listing_status: :draft, tenant: tenant)

    expect { create_release_for(app) }.not_to have_enqueued_job(CatalogIndexPublishJob)
  end
end
