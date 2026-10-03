# frozen_string_literal: true

require 'rails_helper'

# Task 36b-5. Written, NOT run. The client is a strict double: any method the spec does not allow
# fails the example, which is how "never writes" is asserted.
RSpec.describe GoogleAdc::Registrar do
  let(:account) { 'developerAccounts/123' }
  let(:package) { 'com.example.app' }
  let(:resource) { "#{account}/androidPackages/#{package}" }
  let(:fingerprint) { 'ab' * 32 }
  let(:client) { instance_double(GoogleAdc::Client, configured?: true, verified_account_name: account) }

  def run(**options)
    described_class.call(package_name: package, client: client, fingerprint: fingerprint, **options)
  end

  context 'with a package name Google does not know' do
    before do
      allow(client).to receive(:get_package).with(resource).and_return(nil)
      allow(client).to receive(:create_package).with(account, package).and_return('state' => 'DRAFT')
      allow(client).to receive(:get_policy).with(resource).and_return('keySelectionStrategy' => 'USE_ANY_KEY')
      allow(client).to receive(:list_keys).with(resource).and_return([])
      allow(client).to receive(:create_key).with(resource, fingerprint).and_return('state' => 'REGISTERED')
    end

    it 'creates the package and the key and records it as registered' do
      result = run

      expect(result.outcome).to eq(:registered)
      expect(client).to have_received(:create_package).once
      expect(client).to have_received(:create_key).once
      expect(AndroidPackageRegistration.find_by(package_name: package)).to have_attributes(
        state: 'registered', key_fingerprint_sha256: fingerprint, developer_account: account, policy_strategy: 'USE_ANY_KEY'
      )
    end

    it 'records a key Google is still processing as pending' do
      allow(client).to receive(:create_key).and_return('state' => 'IN_REVIEW')

      expect(run.outcome).to eq(:pending)
    end

    it 'records a blocked key as needing review' do
      allow(client).to receive(:create_key).and_return('state' => 'BLOCKED')

      expect(run.outcome).to eq(:needs_review)
    end

    it 'remembers the app and its tenant' do
      app = App.create!(name: 'Tenant app')

      run(app: app)

      expect(AndroidPackageRegistration.find_by(package_name: package).app_id).to eq(app.id)
    end

    it 'does nothing the second time once it is registered' do
      run
      allow(client).to receive(:get_package).and_raise('must not be called')

      expect(run.outcome).to eq(:already_settled)
    end
  end

  context 'with a package that already has the organisation key' do
    it 'changes nothing in Google' do
      allow(client).to receive(:get_package).and_return('state' => 'REGISTERED')
      allow(client).to receive(:get_policy).and_return('keySelectionStrategy' => 'USE_ANY_KEY')
      allow(client).to receive(:list_keys).and_return([{ 'certificateFingerprintSha256' => fingerprint.upcase, 'state' => 'REGISTERED' }])

      expect(run.outcome).to eq(:registered)
    end
  end

  context 'with a package name Google already knows (decision 36-2)' do
    before do
      allow(client).to receive(:get_package).and_return(nil)
      allow(client).to receive(:create_package).and_return('state' => 'DRAFT')
      allow(client).to receive(:get_policy).and_return('keySelectionStrategy' => 'SELECT_KEY_FROM_LIST')
      allow(client).to receive(:list_keys).and_return([])
    end

    it 'stops with needs_review and never adds a key' do
      result = run

      expect(result.outcome).to eq(:needs_review)
      expect(result.registration.last_error).to match(/proof of key ownership/)
      expect(client).not_to receive(:create_key)
    end
  end

  context 'with a package that has keys the organisation did not register' do
    it 'stops with needs_review' do
      allow(client).to receive(:get_package).and_return('state' => 'REGISTERED')
      allow(client).to receive(:get_policy).and_return('keySelectionStrategy' => 'USE_ANY_KEY')
      allow(client).to receive(:list_keys).and_return([{ 'certificateFingerprintSha256' => 'cd' * 32, 'state' => 'REGISTERED' }])

      expect(run.outcome).to eq(:needs_review)
      expect(client).not_to receive(:create_key)
    end
  end

  context 'when Google refuses' do
    it 'records failed with Google\'s words and does not raise' do
      allow(client).to receive(:get_package).and_raise(GoogleAdc::PermanentError, 'Google 400 for POST: INVALID_ARGUMENT')

      result = run

      expect(result.outcome).to eq(:failed)
      expect(AndroidPackageRegistration.find_by(package_name: package)).to have_attributes(state: 'failed', last_error: /INVALID_ARGUMENT/)
    end

    it 'records the message and re-raises on a temporary error, keeping the state' do
      allow(client).to receive(:get_package).and_raise(GoogleAdc::TemporaryError, 'timeout')

      expect { run }.to raise_error(GoogleAdc::TemporaryError)
      expect(AndroidPackageRegistration.find_by(package_name: package)).to have_attributes(state: 'pending', last_error: 'timeout')
    end
  end

  context 'with ADC_DRY_RUN=true' do
    before { stub_const('ENV', ENV.to_hash.merge('ADC_DRY_RUN' => 'true')) }

    it 'reads, plans, writes nothing to Google and saves nothing' do
      allow(client).to receive(:get_package).and_return(nil)

      result = run

      expect(result.outcome).to eq(:dry_run)
      expect(result.planned.join).to include("create package #{package}")
      expect(client).not_to receive(:create_package)
      expect(client).not_to receive(:create_key)
      expect(AndroidPackageRegistration.count).to eq(0)
    end
  end

  context 'with nothing to work with' do
    it 'refuses an invalid package name before any call' do
      expect(described_class.call(package_name: '../x', client: client, fingerprint: fingerprint).outcome).to eq(:invalid_package_name)
    end

    it 'does nothing when the client is not configured' do
      unconfigured = instance_double(GoogleAdc::Client, configured?: false)

      expect(described_class.call(package_name: package, client: unconfigured, fingerprint: fingerprint).outcome).to eq(:not_configured)
    end

    it 'does nothing when there is no organisation signing key' do
      allow(AndroidSigningKey).to receive(:current).and_return(nil)

      expect(described_class.call(package_name: package, client: client).outcome).to eq(:no_signing_key)
    end
  end
end
