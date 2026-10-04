# frozen_string_literal: true

require 'rails_helper'

# Task 40h-b: awaiting_bytes -> uploaded | failed | expired. Needs Postgres. R2 is a fake: no network, no
# bucket. NOT run (the operator said no testing); look here first if CI is red for this slice.
RSpec.describe ReleaseUploadFinalizer do
  let!(:app) { create(:app, name: 'Live app', listing_status: :live, listed_at: Time.current) }
  let(:scheme) { app.schemes.create!(name: 'Main') }
  let(:channel) { scheme.channels.create!(name: 'Android', device_type: :android) }
  let(:declared) { 1234 }
  let(:state) { 'awaiting_bytes' }
  let!(:upload) do
    ReleaseUpload.create!(channel: channel, filename: 'app.aab', declared_size: declared).tap do |u|
      u.update_columns(state: state)
    end
  end
  let(:held) { ReleaseUploadStaging::Head.new(size: 1234, etag: 'abc123') }
  let(:staging) { instance_double(ReleaseUploadStaging, head: held, delete: true) }

  def finalize(now: Time.current)
    described_class.new(upload.reload, staging: staging, now: now).call
  end

  it 'moves the row to uploaded and records what R2 holds' do
    result = finalize

    expect(result.code).to eq(:uploaded)
    expect(result.http).to eq(200)
    upload.reload
    expect(upload.state).to eq('uploaded')
    expect(upload.uploaded_size).to eq(1234)
    expect(upload.etag).to eq('abc123')
    expect(upload.uploaded_at).to be_present
  end

  # Task 40i-a: a successful finalize sends the upload to the stage-1 workflow; nothing else does.
  it 'enqueues the stage-1 dispatch once, on the finalize that wins' do
    expect { finalize }.to have_enqueued_job(ReleaseUploadDispatchJob).with(upload.id).exactly(:once)
    expect { finalize }.not_to have_enqueued_job(ReleaseUploadDispatchJob)
  end

  it 'is idempotent: a second finalize answers 200 and does not ask R2 again' do
    finalize
    result = finalize

    expect(result.code).to eq(:already_uploaded)
    expect(result.http).to eq(200)
    expect(staging).to have_received(:head).once
  end

  context 'when nothing reached the bucket' do
    let(:held) { nil }

    it 'answers 422 and leaves the row open so the client can retry' do
      result = finalize

      expect(result.code).to eq(:no_bytes)
      expect(result.http).to eq(422)
      expect(upload.reload.state).to eq('awaiting_bytes')
    end
  end

  context 'when the staged file is not the declared size' do
    let(:held) { ReleaseUploadStaging::Head.new(size: 9999, etag: 'x') }

    it 'fails the row with the reason and deletes the staged object' do
      result = finalize

      expect(result.code).to eq(:size_mismatch)
      expect(result.http).to eq(422)
      upload.reload
      expect(upload.state).to eq('failed')
      expect(upload.error).to include('9999').and include('1234')
      expect(staging).to have_received(:delete).with(upload)
    end

    it 'still answers the same when the delete fails' do
      allow(staging).to receive(:delete).and_raise(ReleaseStorage::StorageError, 'boom')

      expect(finalize.code).to eq(:size_mismatch)
      expect(upload.reload.state).to eq('failed')
    end
  end

  context 'when the window closed long ago' do
    it 'expires the row without asking R2' do
      result = finalize(now: upload.expires_at + ReleaseUploadFinalizer::GRACE + 1.minute)

      expect(result.code).to eq(:expired)
      expect(result.http).to eq(409)
      expect(upload.reload.state).to eq('expired')
      expect(staging).not_to have_received(:head)
    end

    it 'still accepts a finalize inside the grace period' do
      result = finalize(now: upload.expires_at + 5.minutes)

      expect(result.code).to eq(:uploaded)
    end
  end

  %w[failed expired processing done].each do |other|
    context "when the row is already #{other}" do
      let(:state) { other }

      it 'refuses with 409 and changes nothing' do
        result = finalize

        expect(result.code).to eq(:not_open)
        expect(result.http).to eq(409)
        expect(upload.reload.state).to eq(other)
        expect(staging).not_to have_received(:head)
      end
    end
  end

  it 'answers 503 and leaves the row open when R2 cannot be reached' do
    allow(staging).to receive(:head).and_raise(ReleaseStorage::StorageError, 'R2 head failed')

    result = finalize

    expect(result.code).to eq(:storage_unavailable)
    expect(result.http).to eq(503)
    expect(upload.reload.state).to eq('awaiting_bytes')
  end

  it 'never overwrites a row another request moved in between' do
    allow(staging).to receive(:head) do
      ReleaseUpload.where(id: upload.id).update_all(state: 'expired')
      held
    end

    result = finalize

    expect(result.code).to eq(:not_open)
    expect(upload.reload.state).to eq('expired')
  end
end
