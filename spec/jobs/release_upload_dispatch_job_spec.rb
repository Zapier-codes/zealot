# frozen_string_literal: true

require 'rails_helper'

# Task 40i-a. Written by reading the code, NOT run.
RSpec.describe ReleaseUploadDispatchJob, type: :job do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.apk', declared_size: 10).tap do |row|
      row.update_columns(state: 'uploaded', uploaded_size: 10, uploaded_at: Time.current)
    end
  end

  def dispatcher_double(error: nil)
    double = instance_double(ReleaseUploadDispatcher)
    allow(ReleaseUploadDispatcher).to receive(:new).and_return(double)
    if error
      allow(double).to receive(:call).and_raise(error)
    else
      allow(double).to receive(:call).and_return(true)
    end
  end

  it 'records the dispatch time and leaves the state alone' do
    dispatcher_double
    described_class.perform_now(upload.id)

    upload.reload
    expect(upload.state).to eq('uploaded')
    expect(upload.dispatched_at).to be_present
  end

  it 'fails the upload with the reason when the dispatch is refused' do
    dispatcher_double(error: ReleaseUploadDispatcher::DispatchError.new('GitHub refused the dispatch (HTTP 404)'))
    described_class.perform_now(upload.id)

    upload.reload
    expect(upload.state).to eq('failed')
    expect(upload.error).to include('HTTP 404')
  end

  it 'does nothing for a row that is not uploaded, or was already dispatched' do
    upload.update_columns(dispatched_at: Time.current)
    expect(ReleaseUploadDispatcher).not_to receive(:new)
    described_class.perform_now(upload.id)

    other = ReleaseUpload.create!(channel: channel, filename: 'b.apk', declared_size: 10)
    described_class.perform_now(other.id)
    expect(other.reload.state).to eq('awaiting_bytes')
  end

  it 'does not overwrite a row the sweeper failed in the meantime' do
    double = instance_double(ReleaseUploadDispatcher)
    allow(ReleaseUploadDispatcher).to receive(:new).and_return(double)
    allow(double).to receive(:call) do
      ReleaseUpload.where(id: upload.id).update_all(state: 'failed', error: 'swept')
      true
    end
    described_class.perform_now(upload.id)

    upload.reload
    expect(upload.state).to eq('failed')
    expect(upload.error).to eq('swept')
    expect(upload.dispatched_at).to be_nil
  end
end
