# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AnthropicPlayPublishJob, type: :job do
  let(:app_record) { double('App', play_package_name: 'com.example.app', record_play_setup!: true) }
  let(:release) do
    double('Release',
           id: 1,
           play_store_target?: true,
           play_approval_approved?: true,
           play_publish_published?: false,
           play_publish_publishing?: false,
           bundle_id: 'com.example.app',
           app: app_record,
           update!: true)
  end
  let(:publisher) { instance_double(Anthropic::PlayPublishService, publish!: 'edit-9') }
  let(:preflight) { instance_double(Anthropic::PlayPreflightService) }

  before do
    allow(Release).to receive(:find_by).with(id: 1).and_return(release)
    allow(Anthropic::PlayPreflightService).to receive(:new).and_return(preflight)
    allow(Anthropic::PlayPublishService).to receive(:new).and_return(publisher)
  end

  def result(code, message: 'm')
    Anthropic::PlayPreflightService::Result.new(code: code, package_name: 'com.example.app', message: message)
  end

  it 'publishes when the Play setup is ready' do
    allow(preflight).to receive(:check).with('com.example.app').and_return(result(:ready))

    described_class.perform_now(1)

    expect(publisher).to have_received(:publish!).with(release)
    expect(release).to have_received(:update!).with(hash_including(play_publish_status: :published, play_edit_id: 'edit-9'))
  end

  it 'parks the release as waiting_for_setup, without signing or uploading, when the first upload is missing' do
    allow(preflight).to receive(:check).and_return(result(:package_not_found, message: 'upload the first bundle'))

    described_class.perform_now(1)

    expect(publisher).not_to have_received(:publish!)
    expect(release).to have_received(:update!)
      .with(play_publish_status: :waiting_for_setup, play_publish_error: 'upload the first bundle')
  end

  it 'fails (rather than waits) when the credential is missing' do
    allow(preflight).to receive(:check).and_return(result(:not_configured, message: 'no credential'))

    described_class.perform_now(1)

    expect(publisher).not_to have_received(:publish!)
    expect(release).to have_received(:update!)
      .with(play_publish_status: :failed, play_publish_error: 'no credential')
  end

  it 'does nothing for a release that is already published' do
    allow(release).to receive(:play_publish_published?).and_return(true)
    expect(preflight).not_to receive(:check)

    described_class.perform_now(1)

    expect(publisher).not_to have_received(:publish!)
  end
end
