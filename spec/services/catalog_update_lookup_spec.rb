# frozen_string_literal: true

require 'rails_helper'

# Task 47d: the newest version of a package a device can install in place. Built like release_superseder_spec.rb.
# Written, NOT run (no Postgres or gems in the sandbox that wrote it).
RSpec.describe CatalogUpdateLookup do
  let!(:app) do
    App.create!(name: 'Lookup App', play_package_name: 'com.example.lookup', listing_status: :live,
                listed_at: Time.current)
  end
  let!(:channel) { app.schemes.create!(name: 'Main').channels.create!(name: 'Android', device_type: :android) }

  def make_release(version, **attrs)
    Release.new({ channel: channel, version: version, changelog: [], release_version: "1.0.#{version}",
                  build_version: version.to_s }.merge(attrs)).tap { |r| r.save!(validate: false) }
  end

  # A CI-built release a device can install: compile done and the universal APK fully recorded.
  def make_installable(version, **attrs)
    make_release(version, ci_compile_state: 'done', universal_apk_storage_key: "a1/r#{version}/app.apk",
                          universal_apk_sha256: 'a' * 64, universal_apk_size: 1234, **attrs)
  end

  before { allow(CatalogIndexPublishJob).to receive(:enqueue_for) }

  it 'answers with the newest installable release' do
    make_installable(1)
    newest = make_installable(2, signing_key_checksum: 'AB:CD', min_sdk_version: '26',
                                 changelog: [{ 'message' => 'Faster start' }])

    answer = described_class.call('com.example.lookup')

    expect(answer).to include(
      package_name: 'com.example.lookup', release_id: newest.id, version_code: '2', version_name: '1.0.2',
      sha256: 'a' * 64, size_bytes: 1234, signing_fingerprint: 'AB:CD', min_sdk: '26', changelog: '- Faster start'
    )
    expect(answer[:download_url]).to end_with("/download/releases/#{newest.id}")
    expect(answer[:released_at]).to match(/\A\d{4}-\d\d-\d\dT/)
  end

  it 'compares version codes as versions, not as text, and not by upload order' do
    higher = make_installable(100)
    make_installable(99)

    expect(described_class.call('com.example.lookup')[:release_id]).to eq(higher.id)
  end

  it 'skips a release that is not installable or not available' do
    good = make_installable(1)
    make_release(2)                                          # no compiled APK
    make_installable(3, status: 'halted')                    # halted
    make_installable(4, status: 'pulled')                    # pulled
    make_release(5, ci_compile_state: 'dispatched')          # still compiling

    expect(described_class.call('com.example.lookup')[:release_id]).to eq(good.id)
  end

  it 'never offers a held release' do
    good = make_installable(1)
    make_installable(2, status: 'held')

    expect(described_class.call('com.example.lookup')[:release_id]).to eq(good.id)
  end

  it 'leaves the changelog out when there is none' do
    make_installable(1)

    expect(described_class.call('com.example.lookup')[:changelog]).to be_nil
  end

  it 'is nil when nothing is installable' do
    make_release(1)

    expect(described_class.call('com.example.lookup')).to be_nil
  end

  it 'is nil for an unknown package, a malformed name, or a blank one' do
    make_installable(1)

    expect(described_class.call('com.example.other')).to be_nil
    expect(described_class.call('not a package')).to be_nil
    expect(described_class.call('')).to be_nil
    expect(described_class.call(nil)).to be_nil
  end

  it 'is nil for an app that is not live or is archived' do
    make_installable(1)

    app.update_columns(listing_status: App.listing_statuses[:suspended])
    expect(described_class.call('com.example.lookup')).to be_nil

    app.update_columns(listing_status: App.listing_statuses[:live], archived: true)
    expect(described_class.call('com.example.lookup')).to be_nil
  end

  it 'ignores a release on a channel that is not production' do
    channel.update_columns(track: 'internal')
    make_installable(1)

    expect(described_class.call('com.example.lookup')).to be_nil
  end
end
