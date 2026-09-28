# frozen_string_literal: true

require 'rails_helper'

# Task 37b-iii-s7a: `Release.for_tenant`, the releases of the apps `App.for_tenant` returns.
# Needs Postgres (real `apps.tenant_id` foreign key). App/Scheme/Channel built directly and the
# Release saved with `save!(validate: false)`, the same pattern as
# spec/models/app_catalog_releases_track_spec.rb (no factories for those exist in this repo).
RSpec.describe Release, 'tenant scoping (Task 37b-iii-s7a)' do
  let(:acme) { create(:tenant, tenant_id: 'acme') }

  def make_release(app, version: 1)
    scheme = app.schemes.first || app.schemes.create!(name: 'Main')
    channel = scheme.channels.first || scheme.channels.create!(name: 'Android', device_type: :android)
    release = Release.new(channel: channel, version: version, changelog: [],
                          release_version: "1.0.#{version}", build_version: version.to_s)
    release.save!(validate: false)
    release
  end

  let!(:default_app) { App.create!(name: 'Default app') }
  let!(:acme_app) { App.create!(name: 'Acme app', tenant: acme) }
  let!(:default_release) { make_release(default_app) }
  let!(:acme_release) { make_release(acme_app) }

  it 'gives the default tenant only the releases of apps with no tenant' do
    expect(described_class.for_tenant(nil)).to contain_exactly(default_release)
    expect(described_class.for_tenant('default')).to contain_exactly(default_release)
  end

  it 'gives a tenant only its own apps\' releases, never the default tenant\'s' do
    expect(described_class.for_tenant(acme)).to contain_exactly(acme_release)
    expect(described_class.for_tenant('acme')).to contain_exactly(acme_release)
  end

  it 'matches nothing for an unknown tenant, never falling through to the default catalog' do
    expect(described_class.for_tenant('nobody')).to be_empty
  end

  it 'counts each release once even when an app has several releases' do
    make_release(default_app, version: 2)

    expect(described_class.for_tenant(nil).count).to eq(2)
  end

  it 'counts a release of an archived app (same as App.count does today)' do
    default_app.update_columns(archived: true)

    expect(described_class.for_tenant(nil)).to contain_exactly(default_release)
  end
end
