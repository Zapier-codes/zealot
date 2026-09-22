# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Anthropic::PlayPublishService do
  # Task 19d: publish! used to read release.file.path directly. Publish runs
  # on admin approval, potentially long after upload, so this only covers the
  # part that changed — obtaining the file through ReleaseStorage — not the
  # full Google Play Developer API call (no google-apis-androidpublisher_v3
  # gem in this sandbox; see the class comment).
  let(:credential) { double('PlayCredential') }
  let(:upload_key) { double('PlayUploadKey') }
  let(:app_record) { double('App', play_publish_track: nil) }
  let(:release) { double('Release', bundle_id: 'com.example.app', app: app_record) }
  let(:storage) { instance_double(ReleaseStorage) }

  subject(:service) { described_class.new(credential: credential, upload_key: upload_key) }

  before do
    allow(ReleaseStorage).to receive(:new).with(release).and_return(storage)
  end

  it 'signs the path ReleaseStorage yields, not release.file.path directly' do
    allow(release).to receive(:file).and_return(double(path: '/should-not-be-used.aab'))
    allow(storage).to receive(:with_local_file).and_yield('/from-storage/app.aab')
    allow(service).to receive(:sign_bundle_for_upload).with('/from-storage/app.aab').and_return('/signed/app.aab')
    allow(credential).to receive(:with_credentials_file).and_yield('/creds.json')
    client = double('Client', insert_edit: double(id: 'edit-1'), commit_edit: true)
    allow(service).to receive(:build_client).with('/creds.json').and_return(client)
    allow(service).to receive(:upload_bundle)
    allow(service).to receive(:assign_to_track)

    result = service.publish!(release)

    expect(result).to eq('edit-1')
    expect(service).to have_received(:sign_bundle_for_upload).with('/from-storage/app.aab')
    expect(service).not_to have_received(:sign_bundle_for_upload).with('/should-not-be-used.aab')
  end

  it 'raises PublishError, not a bare storage error, when the file is unobtainable' do
    allow(storage).to receive(:with_local_file).and_raise(ReleaseStorage::MissingFileError, 'gone everywhere')

    expect { service.publish!(release) }
      .to raise_error(Anthropic::PlayPublishService::PublishError, /gone everywhere/)
  end

  it 'still surfaces NotConfiguredError before ever asking storage for the file' do
    service_without_credential = described_class.new(credential: nil, upload_key: upload_key)

    expect { service_without_credential.publish!(release) }
      .to raise_error(Anthropic::PlayPublishService::NotConfiguredError)
    expect(ReleaseStorage).not_to have_received(:new)
  end
end
