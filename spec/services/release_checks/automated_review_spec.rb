# frozen_string_literal: true

require 'rails_helper'

# Z-P2/Z-P3/Z-P4: the automated review runner's verdict logic (the pure half). Written, NOT run (no Ruby in
# the sandbox that wrote it). Uses plain doubles, like base_stats_spec.rb, because the point is the rules,
# not ActiveRecord. The real model columns are supplied for the `record!` shape test.
RSpec.describe ReleaseChecks::AutomatedReview do
  def release(permissions: [], target_sdk_version: 35, signing_key_checksum: 'abc123')
    double('release', permissions: permissions, target_sdk_version: target_sdk_version,
                      signing_key_checksum: signing_key_checksum)
  end

  it 'passes a clean build with no added sensitive permissions, a current target API and a signature' do
    result = described_class.call(release)
    expect(result.verdict).to eq('pass')
    expect(result.reasons).to be_empty
  end

  it 'flags a newly added sensitive permission when compared with the previous release' do
    result = described_class.call(release(permissions: ['android.permission.CAMERA']),
                                  previous_permissions: [])
    expect(result.verdict).to eq('flag')
    expect(result.reasons.map(&:code)).to include('sensitive_permission_added')
  end

  it 'does not flag a sensitive permission that was already present' do
    result = described_class.call(release(permissions: ['android.permission.CAMERA']),
                                  previous_permissions: ['android.permission.CAMERA'])
    expect(result.verdict).to eq('pass')
  end

  it 'flags a target API below the current Play minimum' do
    result = described_class.call(release(target_sdk_version: 30))
    expect(result.verdict).to eq('flag')
    expect(result.reasons.map(&:code)).to include('target_sdk_below_play_minimum')
  end

  it 'flags third-party trackers and normalizes them' do
    tracker = ReleaseChecks::MobsfClient::Tracker.new(name: 'Adjust', category: 'Analytics')
    result = described_class.call(release, trackers: [tracker])
    expect(result.verdict).to eq('flag')
    expect(result.reasons.map(&:code)).to include('third_party_trackers')
    expect(result.trackers.first.name).to eq('Adjust')
  end

  it 'rejects a build with no signing-key checksum and lets reject win over flag' do
    result = described_class.call(release(target_sdk_version: 30, signing_key_checksum: ''))
    expect(result.verdict).to eq('reject')
    expect(result.reasons.map(&:code)).to include('unsigned_apk')
  end

  it 'maps a MobSF report into trackers, tolerating a report with no tracker section' do
    client = ReleaseChecks::MobsfClient.allocate
    expect(client.trackers_from_report({})).to eq([])
    expect(client.trackers_from_report(nil)).to eq([])

    report = { 'trackers' => { 'trackers' => [
      { 'name' => 'Google Analytics', 'categories' => ['Analytics'], 'code_signature' => 'com.google.android.gms.analytics' },
      { 'name' => '', 'categories' => ['Ads'] }
    ] } }
    trackers = client.trackers_from_report(report)
    expect(trackers.size).to eq(1)
    expect(trackers.first.name).to eq('Google Analytics')
    expect(trackers.first.category).to eq('Analytics')
  end
end
