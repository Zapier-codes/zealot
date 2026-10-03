# frozen_string_literal: true

require 'rails_helper'

# Task 36b-6. Written, NOT run.
RSpec.describe GoogleAdcRegisterJob do
  # Plain doubles: the job reads four attributes, and ActiveRecord attribute methods are not
  # reliably visible to verifying doubles.
  let(:key) { double('AndroidSigningKey', checksum: 'sum-1') }
  let(:app) { double('App', play_package_name: 'com.example.app') }
  let(:release) { double('Release', signed?: true, signing_key_checksum: 'sum-1', app: app, bundle_id: nil) }
  let(:registrar) { GoogleAdc::Registrar }

  before do
    stub_const('ENV', ENV.to_hash.merge('ADC_AUTO_REGISTER' => 'true'))
    allow(GoogleAdc::Client).to receive(:configured?).and_return(true)
    allow(Release).to receive(:find_by).with(id: 7).and_return(release)
    allow(AndroidSigningKey).to receive(:current).and_return(key)
    allow(registrar).to receive(:call).and_return(GoogleAdc::Registrar::Result.new(outcome: :registered, planned: []))
  end

  def perform
    described_class.new.perform(7)
  end

  it 'registers the app\'s package name' do
    perform

    expect(registrar).to have_received(:call).with(package_name: 'com.example.app', app: app)
  end

  it 'falls back to the release\'s bundle id when the app has no package name' do
    allow(app).to receive(:play_package_name).and_return(nil)
    allow(release).to receive(:bundle_id).and_return('com.from.release')

    perform

    expect(registrar).to have_received(:call).with(package_name: 'com.from.release', app: app)
  end

  it 'does nothing unless ADC_AUTO_REGISTER is "true"' do
    stub_const('ENV', ENV.to_hash.merge('ADC_AUTO_REGISTER' => 'false'))

    perform

    expect(registrar).not_to have_received(:call)
  end

  it 'does nothing when Google credentials are missing' do
    allow(GoogleAdc::Client).to receive(:configured?).and_return(false)

    perform

    expect(registrar).not_to have_received(:call)
  end

  it 'does nothing for a release signed with a different key (decision 36-4)' do
    allow(release).to receive(:signing_key_checksum).and_return('another-key')

    perform

    expect(registrar).not_to have_received(:call)
  end

  it 'does nothing for an unsigned release' do
    allow(release).to receive(:signed?).and_return(false)

    perform

    expect(registrar).not_to have_received(:call)
  end

  it 'does nothing when no package name is known' do
    allow(app).to receive(:play_package_name).and_return(nil)

    perform

    expect(registrar).not_to have_received(:call)
  end

  it 'swallows an unexpected error so the upload that caused it is never affected' do
    allow(registrar).to receive(:call).and_raise(StandardError, 'boom')

    expect { perform }.not_to raise_error
  end

  it 'lets a temporary error through so the job is retried' do
    allow(registrar).to receive(:call).and_raise(GoogleAdc::TemporaryError, 'timeout')

    expect { perform }.to raise_error(GoogleAdc::TemporaryError)
  end
end
