# frozen_string_literal: true

require 'rails_helper'

# Task 40g-2: direct uploads never finalized become expired (and their staged object is deleted); finalized ones
# nobody processed become failed. Needs Postgres. Imitates ci_compile_sweeper_job_spec.rb; R2 is a double.
# NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe ReleaseUploadSweeperJob do
  let!(:app) { create(:app, name: 'Sweep app') }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:staging) { instance_double(ReleaseUploadStaging, delete: true) }

  def make_upload(state:, expires_at: nil, uploaded_at: nil)
    ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: 100).tap do |u|
      u.update_columns(state: state, expires_at: expires_at, uploaded_at: uploaded_at)
    end
  end

  before do
    allow(ReleaseUploadStaging).to receive(:configured?).and_return(true)
    allow(ReleaseUploadStaging).to receive(:new).and_return(staging)
  end

  describe '.stale_after' do
    it 'defaults to 90 minutes and reads RELEASE_UPLOAD_STALE_AFTER_MINUTES' do
      stub_const('ENV', ENV.to_hash.merge('RELEASE_UPLOAD_STALE_AFTER_MINUTES' => nil))
      expect(described_class.stale_after).to eq(90.minutes)

      stub_const('ENV', ENV.to_hash.merge('RELEASE_UPLOAD_STALE_AFTER_MINUTES' => '30'))
      expect(described_class.stale_after).to eq(30.minutes)
    end

    %w[0 -5 abc].each do |bad|
      it "falls back to the default for #{bad.inspect}" do
        stub_const('ENV', ENV.to_hash.merge('RELEASE_UPLOAD_STALE_AFTER_MINUTES' => bad))
        expect(described_class.stale_after).to eq(90.minutes)
      end
    end
  end

  describe 'awaiting_bytes' do
    it 'expires a row past its window plus the finalize grace and deletes the staged object' do
      upload = make_upload(state: 'awaiting_bytes', expires_at: 3.hours.ago)

      described_class.perform_now

      expect(upload.reload).to have_attributes(state: 'expired')
      expect(upload.error).to be_present
      expect(staging).to have_received(:delete).with(upload)
    end

    it 'leaves a row inside the window, and one inside the grace, alone' do
      open_row = make_upload(state: 'awaiting_bytes', expires_at: 1.hour.from_now)
      grace_row = make_upload(state: 'awaiting_bytes', expires_at: 5.minutes.ago)

      described_class.perform_now

      expect(open_row.reload.state).to eq('awaiting_bytes')
      expect(grace_row.reload.state).to eq('awaiting_bytes')
      expect(staging).not_to have_received(:delete)
    end

    # Task 40s-c: a half-sent multipart upload is aborted, so R2 stops keeping its parts.
    it 'aborts the multipart upload of an expired multipart row before deleting the object' do
      multi = instance_double(ReleaseUploadStaging, delete: true, abort_multipart: true)
      allow(ReleaseUploadStaging).to receive(:new).and_return(multi)
      upload = make_upload(state: 'awaiting_bytes', expires_at: 8.hours.ago)
      upload.update_columns(part_size: 16 * 1024 * 1024, multipart_upload_id: 'mp-1')

      described_class.perform_now

      expect(upload.reload.state).to eq('expired')
      expect(multi).to have_received(:abort_multipart).with(upload)
      expect(multi).to have_received(:delete).with(upload)
    end

    it 'does not abort anything for a single PUT row' do
      multi = instance_double(ReleaseUploadStaging, delete: true)
      allow(ReleaseUploadStaging).to receive(:new).and_return(multi)
      make_upload(state: 'awaiting_bytes', expires_at: 3.hours.ago)

      expect { described_class.perform_now }.not_to raise_error
      expect(multi).to have_received(:delete)
    end

    it 'still expires the row when the delete fails' do
      allow(staging).to receive(:delete).and_raise(ReleaseStorage::StorageError, 'boom')
      upload = make_upload(state: 'awaiting_bytes', expires_at: 3.hours.ago)

      expect { described_class.perform_now }.not_to raise_error
      expect(upload.reload.state).to eq('expired')
    end

    it 'does not touch the bucket when staging is not configured' do
      allow(ReleaseUploadStaging).to receive(:configured?).and_return(false)
      upload = make_upload(state: 'awaiting_bytes', expires_at: 3.hours.ago)

      described_class.perform_now

      expect(upload.reload.state).to eq('expired')
      expect(ReleaseUploadStaging).not_to have_received(:new)
    end

    it 'does not overwrite a row finalized after it was read' do
      upload = make_upload(state: 'awaiting_bytes', expires_at: 3.hours.ago)
      allow(ReleaseUpload).to receive(:stale_awaiting).and_wrap_original do |original, *args|
        original.call(*args).tap { upload.update_columns(state: 'uploaded', uploaded_at: Time.current) }
      end

      described_class.perform_now

      expect(upload.reload.state).to eq('uploaded')
    end
  end

  describe 'uploaded' do
    it 'fails a finalized row nobody processed within the limit and keeps its object' do
      upload = make_upload(state: 'uploaded', uploaded_at: 3.hours.ago)

      described_class.perform_now

      expect(upload.reload.state).to eq('failed')
      expect(upload.error).to include('not processed')
      expect(staging).not_to have_received(:delete)
    end

    it 'leaves a recent finalized row alone' do
      upload = make_upload(state: 'uploaded', uploaded_at: 5.minutes.ago)

      described_class.perform_now

      expect(upload.reload.state).to eq('uploaded')
    end
  end

  # Task 40i-c: a processing row has a held release with no file; if stage 2 never reports, it is failed.
  describe 'processing' do
    let(:metadata) do
      { 'kind' => 'aab', 'package_name' => 'com.example.app', 'version_code' => 3, 'version_name' => '1.0',
        'file_sha256' => 'a' * 64, 'file_size' => 100 }
    end

    # The real path to `processing`: a reported upload that the release builder turned into a held release.
    def make_processing(stage1_at:)
      upload = make_upload(state: 'uploaded')
      upload.update_columns(uploaded_size: 100, stage1_at: Time.current, metadata: metadata)
      ReleaseUploadReleaseBuilder.new(upload.reload, staging: staging).call
      upload.reload.tap { |row| row.update_columns(stage1_at: stage1_at) }
    end

    it 'fails a row whose stage 2 never reported, writes the reason on the held release and keeps it held' do
      upload = make_processing(stage1_at: 3.hours.ago)

      described_class.perform_now

      expect(upload.reload.state).to eq('failed')
      expect(upload.error).to include('did not finish')
      expect(upload.release.reload).to have_attributes(status: 'held', ci_compile_state: 'failed')
      expect(upload.release.ci_compile_error).to include('upload it again')
    end

    it 'leaves a row whose stage 1 just reported alone' do
      upload = make_processing(stage1_at: 5.minutes.ago)

      described_class.perform_now

      expect(upload.reload.state).to eq('processing')
      expect(upload.release.reload.ci_compile_state).to be_nil
    end
  end

  it 'never touches done, failed or expired rows, nor an uploaded or processing row that is still fresh' do
    rows = %w[done failed expired].map do |state|
      make_upload(state: state, expires_at: 3.hours.ago, uploaded_at: 3.hours.ago)
    end

    described_class.perform_now

    expect(rows.map { |r| r.reload.state }).to eq(%w[done failed expired])
  end
end
