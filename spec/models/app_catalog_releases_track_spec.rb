# frozen_string_literal: true

require 'rails_helper'

# Task 30b: only production-track channels feed the catalog index.
# App/Scheme/Channel built directly (no factories for Scheme/Channel
# exist in this repo -- checked spec/factories/), same pattern
# spec/policies/app_ownership_spec.rb already uses. Release built and
# persisted with validation skipped (`save!(validate: false)`), same
# workaround release_parser_spec.rb/serializer_spec.rb use for the
# create-only `file` presence validation that has nothing to do with
# what this spec is testing.
RSpec.describe App, 'catalog_releases (Task 30b track scoping)' do
  let(:app) { App.create!(name: 'Tracked app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }

  def make_channel(track:)
    scheme.channels.create!(name: "Android #{track}", device_type: :android, track: track)
  end

  def make_release(channel, version:)
    release = Release.new(channel: channel, version: version, changelog: [],
                           release_version: "1.0.#{version}", build_version: version.to_s)
    release.save!(validate: false)
    release
  end

  it 'defaults an existing/new channel to production (no silent disappearance from the index)' do
    channel = scheme.channels.create!(name: 'Android', device_type: :android)

    expect(channel).to be_track_production
  end

  it 'includes releases from a production-track channel' do
    channel = make_channel(track: 'production')
    release = make_release(channel, version: 1)

    expect(app.catalog_releases).to contain_exactly(release)
  end

  it 'excludes releases from internal/closed/open-track channels' do
    %w[internal closed open].each do |track|
      channel = make_channel(track: track)
      make_release(channel, version: 1)
    end

    expect(app.catalog_releases).to be_empty
  end

  it 'includes only the production releases when tracks are mixed' do
    production_channel = make_channel(track: 'production')
    internal_channel = make_channel(track: 'internal')
    production_release = make_release(production_channel, version: 1)
    make_release(internal_channel, version: 2)

    expect(app.catalog_releases).to contain_exactly(production_release)
  end

  it 'still returns every release through #recently_release/#channel_ids, track-unscoped' do
    internal_channel = make_channel(track: 'internal')
    release = make_release(internal_channel, version: 1)

    # #catalog_releases (the index-facing method) excludes it...
    expect(app.catalog_releases).to be_empty
    # ...but the management-facing methods this slice deliberately left
    # alone still see it.
    expect(app.channel_ids).to include(internal_channel.id)
    expect(app.recently_release).to eq(release)
  end

  it 'rejects a track outside the four Play-parity values' do
    channel = scheme.channels.build(name: 'Bad', device_type: :android)

    expect { channel.track = 'beta' }.to raise_error(ArgumentError)
  end
end
