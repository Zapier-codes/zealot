# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Anthropic::PlayPreflightService do
  let(:credential) { instance_double(PlayCredential, service_account_email: 'publishing@example.iam.gserviceaccount.com') }
  let(:client) { double('AndroidPublisherService') }
  let(:package) { 'com.example.app' }

  subject(:service) { described_class.new(credential: credential) }

  before do
    allow(credential).to receive(:with_credentials_file).and_yield('/tmp/play-credentials.json')
    allow(service).to receive(:build_client).and_return(client)
  end

  it 'reports no_package_name without calling Google when the package is blank' do
    expect(client).not_to receive(:insert_edit)

    result = service.check('  ')

    expect(result.code).to eq(:no_package_name)
    expect(result.app_status).to eq(:unchecked)
  end

  it 'reports not_configured when there is no credential' do
    result = described_class.new(credential: nil).check(package)

    expect(result.code).to eq(:not_configured)
    expect(result.app_status).to eq(:needs_credentials)
  end

  it 'is ready when Google opens an edit, and discards that edit again' do
    allow(client).to receive(:insert_edit).with(package, {}).and_return(double(id: 'edit-1'))
    expect(client).to receive(:delete_edit).with(package, 'edit-1')

    result = service.check(package)

    expect(result).to be_ready
    expect(result.edit_id).to eq('edit-1')
    expect(result.app_status).to eq(:ready)
  end

  it 'stays ready when discarding the edit fails' do
    allow(client).to receive(:insert_edit).and_return(double(id: 'edit-1'))
    allow(client).to receive(:delete_edit).and_raise(StandardError, 'boom')

    expect(service.check(package)).to be_ready
  end

  it 'maps a 404 to package_not_found (waiting for the first manual upload)' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::ClientError.new("Package not found: #{package}", status_code: 404))

    result = service.check(package)

    expect(result.code).to eq(:package_not_found)
    expect(result.app_status).to eq(:needs_first_upload)
    expect(result).to be_waiting_for_setup
    expect(result.message).to include(package)
  end

  it 'maps a 403 to access_denied, a failure to fix rather than a wait (one service account covers every app)' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::ClientError.new('forbidden', status_code: 403))

    result = service.check(package)

    expect(result.code).to eq(:access_denied)
    expect(result.app_status).to eq(:needs_access)
    expect(result).not_to be_waiting_for_setup
    expect(result.message).to include('publishing@example.iam.gserviceaccount.com')
  end

  it 'maps an authorization error to auth_failed, which is not something to wait for' do
    allow(client).to receive(:insert_edit)
      .and_raise(Google::Apis::AuthorizationError.new('unauthorized', status_code: 401))

    result = service.check(package)

    expect(result.code).to eq(:auth_failed)
    expect(result).not_to be_waiting_for_setup
  end

  it 'maps anything unexpected to error' do
    allow(client).to receive(:insert_edit).and_raise(RuntimeError, 'network down')

    result = service.check(package)

    expect(result.code).to eq(:error)
    expect(result.app_status).to eq(:check_failed)
  end
end
