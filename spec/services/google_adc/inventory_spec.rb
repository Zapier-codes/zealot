# frozen_string_literal: true

require 'rails_helper'

# Task 36b-2. Written, NOT run. The client double lists only the READ methods, so a call to any
# write method fails the example: that is the "reads only" guarantee.
RSpec.describe GoogleAdc::Inventory do
  let(:account) { 'developerAccounts/123' }
  let(:client) do
    instance_double(
      GoogleAdc::Client,
      verified_account_name: account,
      list_accounts: [{ 'name' => account, 'displayName' => 'Org Ltd', 'verificationState' => 'VERIFIED' }],
      list_packages: [{ 'name' => "#{account}/androidPackages/com.known", 'packageName' => 'com.known', 'state' => 'REGISTERED' }],
      list_keys: [{ 'certificateFingerprintSha256' => 'ab' * 32, 'state' => 'REGISTERED' }]
    )
  end

  before do
    allow(GoogleAdc::StatusClient).to receive(:configured?).and_return(false)
    App.create!(name: 'Known', play_package_name: 'com.known')
    App.create!(name: 'Unknown', play_package_name: 'com.unknown')
  end

  it 'lists Google\'s packages beside Zealot\'s apps and the names Google lacks' do
    report = described_class.call(client: client)

    expect(report.display_name).to eq('Org Ltd')
    expect(report.rows.map(&:package_name)).to eq(['com.known'])
    expect(report.rows.first.zealot_apps).to eq(['Known'])
    expect(report.unregistered).to eq(['com.unknown'])
    expect(report.to_text).to include('com.known', 'Zealot package names not in Google: com.unknown')
  end

  it 'asks the Status API only when a key is configured' do
    status_client = instance_double(GoogleAdc::StatusClient)
    allow(GoogleAdc::StatusClient).to receive(:configured?).and_return(true)
    allow(status_client).to receive(:check).with('com.known').and_return('registrationStatus' => 'REGISTERED')

    report = described_class.call(client: client, status_client: status_client)

    expect(report.rows.first.status).to eq('registrationStatus' => 'REGISTERED')
  end
end
